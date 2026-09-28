#!/usr/bin/env python3
"""Check arbitrary host battery readings, AC input and synthetic-charge isolation."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SCRIPT = r'''
local m = manager.machine
local p = m.devices[":maincpu"].spaces["program"]
local host_port = m.ioport.ports[":HOST_BATTERY"]
if not host_port then
    print("FAIL: HOST_BATTERY input missing")
    m:exit()
    return
end
local host = host_port:field(0xff)
local ac = m.ioport.ports[":POWER_SUPPLY"]:field(1)
local frames = 0
local failures = 0
local function check(label, got, expected)
    if got ~= expected then
        failures = failures + 1
        print(string.format("FAIL: %s got %d expected %d", label, got, expected))
    end
end
local function adc(channel)
    p:write_u32(0x10c00080, 0x54000000 | channel)
    p:write_u32(0x10c00080, 0x58000000)
    return (p:read_u32(0x10c00088) >> 5) & 0x03ff
end
emu.register_frame_done(function()
    frames = frames + 1
    if frames == 5 then
        check("normal main", adc(24), 200)
        check("normal backup", adc(28), 300)
        ac.user_value = 1
        p:write_u32(0x10c00184, p:read_u32(0x10c00184) | 2)
        host:set_value(38 | 128)
    elseif frames == 6 then
        check("37 percent", adc(24), 346)
        check("host AC attached", (p:read_u32(0x10c001c4) >> 30) & 1, 1)
        check("healthy backup", adc(28), 1000)
    elseif frames == 126 then
        check("no synthetic charging", adc(24), 346)
        ac.user_value = 0
        host:clear_value()
    elseif frames == 127 then
        check("normal charge preserved", adc(24), 200)
        check("normal backup restored", adc(28), 300)
        ac.user_value = 1
        host:set_value(1)
    elseif frames == 128 then
        check("zero percent", adc(24), 80)
        check("host AC detached", (p:read_u32(0x10c001c4) >> 30) & 1, 0)
        host:set_value(101)
    elseif frames == 129 then
        check("100 percent", adc(24), 800)
        host:set_value(2)
    elseif frames == 130 then
        check("one percent rounding", adc(24), 87)
        host:clear_value()
    elseif frames == 131 then
        check("configured AC restored", (p:read_u32(0x10c001c4) >> 30) & 1, 1)
        ac.user_value = 0
        host:set_value(1)
    elseif frames >= 132 and frames <= 232 then
        local percent = frames - 132
        check("percentage " .. percent, adc(24), 80 + math.floor(percent * 7.2 + 0.5))
        if percent < 100 then host:set_value(percent + 2)
        else
            if failures == 0 then print("PASS: host battery mapping and charge isolation") end
            m:exit()
        end
    end
end)
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mame", type=Path, default=ROOT.parent / "mame/datarover")
    parser.add_argument("--rompath", type=Path, default=Path(os.environ.get("MAGIC_CAP_ASSETS", ROOT.parent / "magic-cap-assets")) / "roms")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="host-battery-") as temporary:
        work = Path(temporary)
        (work / "cfg").mkdir()
        (work / "cfg/datarover840.cfg").write_text('''<mameconfig version="10"><system name="datarover840"><input>
<port tag=":BOOT_MODE" type="CONFIG" mask="8" defvalue="8" value="0" />
<port tag=":BATTERY" type="CONFIG" mask="3" defvalue="0" value="1" />
<port tag=":BATTERY" type="CONFIG" mask="12" defvalue="0" value="8" />
</input></system></mameconfig>''')
        (work / "test.lua").write_text(SCRIPT)
        command = [str(args.mame.resolve()), "datarover840", "-rompath", str(args.rompath.resolve()),
                   "-cfg_directory", str(work / "cfg"), "-nvram_directory", str(work / "nvram"),
                   "-autoboot_delay", "0", "-autoboot_script", str(work / "test.lua"),
                   "-video", "none", "-sound", "none", "-videodriver", "dummy", "-audiodriver", "dummy",
                   "-nothrottle", "-skip_gameinfo", "-seconds_to_run", "5"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        output = result.stdout + result.stderr
        print(output)
        passed = result.returncode == 0 and "PASS: host battery" in output and "FAIL:" not in output
        if not passed:
            print(f"FAIL: host battery regression incomplete or failed (MAME exit {result.returncode})")
        return 0 if passed else 1

if __name__ == "__main__":
    raise SystemExit(main())
