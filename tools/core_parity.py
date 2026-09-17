#!/usr/bin/env python3
"""libdatarover parity gate: shim framebuffer dump vs Lua reference dump.

Both paths boot the same datarover binary with identical ROM/NVRAM/cfg
(fresh temp dirs per side) and dump the same guest 2bpp framebuffer bytes
(480*320/4 = 38400) at the same emulated frame:

- reference: MAME Lua autoboot script reads guest DRAM at the Dino
  video-high-buffer base register (0x10c00030 masked to 0xfffffff0,
  fallback 0x003f6a00) via program:read_u32 and writes BE words to disk.
- shim: the in-process parity dumper compiled into the binary
  (src/libdatarover/datarover_shim.cpp, armed via DATAROVER_CORE_DUMP /
  DATAROVER_CORE_FRAMES) reads the same guest words through the same
  scanout math the driver's screen_update uses.

The buffers are compared byte-for-byte: PARITY OK or the first differing
offset, exit nonzero. Framebuffer-only scope: Task 2's known gaps (Cntd
double-ack omitted, PTY slave fd not raw) do not affect this gate and no
package delivery is claimed here.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ASSETS_ROOT = Path(
    os.environ.get("MAGIC_CAP_ASSETS", REPO_ROOT.parent / "magic-cap-assets")
).expanduser()
DEFAULT_MAME = REPO_ROOT.parent / "mame" / "datarover"
DEFAULT_ROMPATH = ASSETS_ROOT / "roms"
FB_SIZE = 480 * 320 // 4
DEFAULT_FRAMES = 600
DEFAULT_TIMEOUT = 180


def reference_script(dump_path: Path, frames: int) -> str:
    """Lua that dumps the guest framebuffer words at the target frame."""
    return f"""local machine = manager.machine
local frames = 0
emu.register_frame_done(function()
    frames = frames + 1
    if frames == {frames} then
        local program = machine.devices[":maincpu"].spaces["program"]
        local base = program:read_u32(0x10c00030) & 0xfffffff0
        if base > (0x00400000 - {FB_SIZE}) then base = 0x003f6a00 end
        local f = io.open({str(dump_path)!r}, "wb")
        for offset = 0, {FB_SIZE - 4}, 4 do
            f:write(string.pack(">I4", program:read_u32(base + offset)))
        end
        f:close()
        print(string.format("PARITY_REF_OK base=%08X", base))
        machine:exit()
    end
end)
"""


def run_side(
    mame: Path,
    rompath: Path,
    workdir: Path,
    dump_path: Path,
    frames: int,
    timeout: int,
    use_shim: bool,
    lua_path: Path | None,
) -> tuple[int, bytes]:
    """Boot one side; return (returncode, combined output)."""
    nvram_dir = workdir / "nvram"
    cfg_dir = workdir / "cfg"
    snapshot_dir = workdir / "snapshots"
    nvram_dir.mkdir(parents=True)
    cfg_dir.mkdir(exist_ok=True)
    snapshot_dir.mkdir(exist_ok=True)
    command = [
        str(mame),
        "datarover840",
        "-rompath",
        str(rompath),
        "-nvram_directory",
        str(nvram_dir),
        "-cfg_directory",
        str(cfg_dir),
        "-snapshot_directory",
        str(snapshot_dir),
        "-video",
        "none",
        "-sound",
        "none",
        "-videodriver",
        "dummy",
        "-audiodriver",
        "dummy",
        "-nothrottle",
        "-skip_gameinfo",
    ]
    env = dict(os.environ)
    if use_shim:
        command.extend(["-autoboot_delay", "0"])
        env["DATAROVER_CORE_DUMP"] = str(dump_path)
        env["DATAROVER_CORE_FRAMES"] = str(frames)
    else:
        assert lua_path is not None
        command.extend(
            ["-autoboot_delay", "0", "-autoboot_script", str(lua_path)]
        )
        env.pop("DATAROVER_CORE_DUMP", None)
        env.pop("DATAROVER_CORE_FRAMES", None)
    try:
        completed = subprocess.run(
            command,
            cwd=mame.parent,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        print(
            f"error: {'shim' if use_shim else 'reference'} side timed out "
            f"after {timeout}s; artifacts: {workdir}",
            file=sys.stderr,
        )
        return 124, b""
    return completed.returncode, completed.stdout


def compare_buffers(reference: bytes, shim: bytes) -> int:
    """Byte-for-byte compare; 0 on parity, 1 on first diff."""
    if len(reference) != FB_SIZE:
        print(
            f"FAIL: reference dump is {len(reference)} bytes, "
            f"expected {FB_SIZE}",
            file=sys.stderr,
        )
        return 1
    if len(shim) != FB_SIZE:
        print(
            f"FAIL: shim dump is {len(shim)} bytes, expected {FB_SIZE}",
            file=sys.stderr,
        )
        return 1
    for offset, (want, got) in enumerate(zip(reference, shim)):
        if want != got:
            print(
                f"FAIL: first diff at offset {offset} "
                f"(0x{offset:04x}): reference 0x{want:02x} != "
                f"shim 0x{got:02x}",
                file=sys.stderr,
            )
            return 1
    print(f"PARITY OK ({FB_SIZE} bytes identical)")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mame",
        type=Path,
        default=DEFAULT_MAME,
        help=f"DataRover MAME executable (default: {DEFAULT_MAME})",
    )
    parser.add_argument(
        "--rompath",
        type=Path,
        default=DEFAULT_ROMPATH,
        help=f"MAME ROM search path (default: {DEFAULT_ROMPATH})",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=DEFAULT_FRAMES,
        help=f"emulated frame to dump (default: {DEFAULT_FRAMES})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"per-side timeout in seconds (default: {DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        "--keepdir",
        type=Path,
        help="keep run artifacts under this directory (default: temp dir)",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    mame = args.mame.expanduser().resolve()
    rompath = args.rompath.expanduser().resolve()
    if not mame.is_file():
        print(f"error: MAME executable not found: {mame}", file=sys.stderr)
        return 2
    if not rompath.is_dir():
        print(f"error: ROM path not found: {rompath}", file=sys.stderr)
        return 2
    if args.frames <= 0:
        print("error: --frames must be positive", file=sys.stderr)
        return 2

    if args.keepdir is not None:
        root = args.keepdir.expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        run_sides(root)
    else:
        with tempfile.TemporaryDirectory(prefix="core-parity-") as tmp:
            return run_sides(Path(tmp))
    return 0


def run_sides(root: Path) -> int:
    # Re-parse argv-free: run_sides is called with the already-validated
    # module-level args via closure below; kept separate for testability.
    raise NotImplementedError


def run_gate(
    mame: Path,
    rompath: Path,
    root: Path,
    frames: int,
    timeout: int,
) -> int:
    ref_dir = root / "reference"
    shim_dir = root / "shim"
    ref_dump = ref_dir / "framebuffer.bin"
    shim_dump = shim_dir / "framebuffer.bin"
    lua_path = ref_dir / "parity-reference.lua"
    ref_dir.mkdir(parents=True, exist_ok=True)
    shim_dir.mkdir(parents=True, exist_ok=True)
    lua_path.write_text(
        reference_script(ref_dump, frames), encoding="utf-8"
    )

    ref_code, ref_out = run_side(
        mame, rompath, ref_dir, ref_dump, frames, timeout, False, lua_path
    )
    (ref_dir / "mame-output.txt").write_bytes(ref_out)
    if ref_code != 0 or not ref_dump.is_file():
        print(
            f"error: reference side exited with status {ref_code}; "
            f"see {ref_dir / 'mame-output.txt'}",
            file=sys.stderr,
        )
        return 2

    shim_code, shim_out = run_side(
        mame, rompath, shim_dir, shim_dump, frames, timeout, True, None
    )
    (shim_dir / "mame-output.txt").write_bytes(shim_out)
    if shim_code != 0 or not shim_dump.is_file():
        print(
            f"error: shim side exited with status {shim_code}; "
            f"see {shim_dir / 'mame-output.txt'}",
            file=sys.stderr,
        )
        return 2

    return compare_buffers(ref_dump.read_bytes(), shim_dump.read_bytes())


if __name__ == "__main__":
    # Bind run_sides to the validated CLI args (keeps main() thin and the
    # gate importable for tests without subprocess side effects).
    _args = parse_args(sys.argv[1:])
    _mame = _args.mame.expanduser().resolve()
    _rompath = _args.rompath.expanduser().resolve()
    if not _mame.is_file():
        print(
            f"error: MAME executable not found: {_mame}", file=sys.stderr
        )
        sys.exit(2)
    if not _rompath.is_dir():
        print(
            f"error: ROM path not found: {_rompath}", file=sys.stderr
        )
        sys.exit(2)
    if _args.frames <= 0:
        print("error: --frames must be positive", file=sys.stderr)
        sys.exit(2)

    def run_sides(root: Path) -> int:  # noqa: F811
        return run_gate(_mame, _rompath, root, _args.frames, _args.timeout)

    if _args.keepdir is not None:
        _root = _args.keepdir.expanduser().resolve()
        _root.mkdir(parents=True, exist_ok=True)
        sys.exit(run_sides(_root))
    else:
        with tempfile.TemporaryDirectory(prefix="core-parity-") as _tmp:
            sys.exit(run_sides(Path(_tmp)))
