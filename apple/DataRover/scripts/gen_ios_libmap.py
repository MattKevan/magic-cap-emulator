#!/usr/bin/env python3
"""Regenerate the iOS per-library compile map from the MAME fork.

`inject_mame_sources.py` replays each source file's owning GENie library
defines/includes into the Xcode project. Those live in the fork's generated
makefiles, which GENie itself writes:

    $(MAME_DIR)/build/projects/sdl3/mamedatarover/gmake-osx-clang/*.make

so the map is reproducible from a fresh clone:

    python3 scripts/gen_ios_libmap.py --mame-dir ../../../mame

`inject_mame_sources.py` calls this automatically when the map is absent.

Output (default /tmp/ios_libmap.json) is {"owner": {source: lib},
"incs": {lib: [dir]}, "defs": {lib: [-D...]}} — the shape the injector reads.
If the fork has never generated makefiles, run this in the MAME clone first:

    make SUBTARGET=datarover SOURCES=src/mame/skeleton/datarover.cpp REGENIE=1

The makefiles hold one block per configuration; this reads `release`, which is
what the injected per-file flags mirror.
"""
import argparse
import glob
import json
import os
import re
import sys

DEFAULT_SUBTARGET = "datarover"
DEFAULT_CONFIG = "release"
DEFAULT_OUT = "/tmp/ios_libmap.json"

# Object paths lose their source extension, so map back by probing. Order is
# only a tie-breaker; every existing match is recorded.
SOURCE_EXTS = (".c", ".cpp", ".mm", ".m", ".cc", ".cxx", ".S", ".s", ".asm")

CONFIG_BLOCK = r"^ifeq \(\$\(config\),{config}\)\s*$(.*?)^endif\s*$"


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def config_block(text, config):
    m = re.search(CONFIG_BLOCK.format(config=re.escape(config)), text,
                  re.M | re.S)
    if not m:
        raise SystemExit(f"config block '{config}' not found")
    return m.group(1)


def parse_defines(block):
    out = []
    for m in re.finditer(r"^\s*DEFINES\s*\+=\s*(.*)$", block, re.M):
        out.extend(t for t in m.group(1).split() if t.startswith("-D"))
    return out


def parse_includes(block):
    """MAME-relative include dirs, deduped in makefile order."""
    out = []
    for m in re.finditer(r"^\s*INCLUDES\s*\+=\s*(.*)$", block, re.M):
        for quoted, bare in re.findall(r'-I"([^"]+)"|-I(\S+)', m.group(1)):
            inc = quoted or bare
            # Absolute dirs (SDK, brew prefixes) are not per-file MAME flags.
            if os.path.isabs(inc):
                continue
            rel = re.sub(r"^(\.\./)+", "", inc)
            rel = re.sub(r"^\./", "", rel)
            # Brew prefixes reach here with their leading slash stripped.
            if rel.startswith(("opt/", "usr/", "Applications/", "Library/")):
                continue
            # gmake paths are relative to the project dir, where
            # ../../../../generated resolves under the build tree.
            if rel == "generated" or rel.startswith("generated/"):
                rel = "build/" + rel
            if rel and rel not in out:
                out.append(rel)
    return out


def parse_objects(block):
    """Object paths (extension stripped), MAME-root relative."""
    out = []
    for m in re.finditer(r"^\s*OBJECTS\s*:=\s*\\\s*$(.*?)(?=^[^\s\\]|\Z)",
                         block, re.M | re.S):
        for line in m.group(1).splitlines():
            entry = line.strip().rstrip("\\").strip()
            if not entry.startswith("$(OBJDIR)/"):
                continue
            out.append(entry[len("$(OBJDIR)/"):-len(".o")])
    return out


def resolve_sources(mame_dir, obj_path, cache):
    if obj_path in cache:
        return cache[obj_path]
    found = [obj_path + ext for ext in SOURCE_EXTS
             if os.path.isfile(os.path.join(mame_dir, obj_path + ext))]
    if not found:
        # Extension outside SOURCE_EXTS: accept whatever glob matches.
        base = os.path.join(mame_dir, obj_path)
        found = [os.path.relpath(p, mame_dir)
                 for p in sorted(glob.glob(base + ".*"))]
    cache[obj_path] = found
    return found


def generate(mame_dir, subtarget=DEFAULT_SUBTARGET, config=DEFAULT_CONFIG):
    projdir = os.path.join(mame_dir, "build", "projects", "sdl3",
                           "mame" + subtarget, "gmake-osx-clang")
    if not os.path.isdir(projdir):
        raise SystemExit(
            f"no GENie output at {projdir}\n"
            f"generate it in the MAME clone with:\n"
            f"  make SUBTARGET={subtarget} "
            f"SOURCES=src/mame/skeleton/datarover.cpp REGENIE=1")
    owner, incs, defs = {}, {}, {}
    cache = {}
    for name in sorted(os.listdir(projdir)):
        if not name.endswith(".make"):
            continue
        lib = name[:-len(".make")]
        block = config_block(read(os.path.join(projdir, name)), config)
        defs[lib] = parse_defines(block)
        incs[lib] = parse_includes(block)
        for obj in parse_objects(block):
            for src in resolve_sources(mame_dir, obj, cache):
                owner[src] = lib
    return {"owner": owner, "incs": incs, "defs": defs}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mame-dir", default=os.environ.get("MAME_DIR", "../mame"))
    ap.add_argument("--subtarget", default=DEFAULT_SUBTARGET)
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    mame_dir = os.path.abspath(args.mame_dir)
    data = generate(mame_dir, args.subtarget, args.config)
    with open(args.out, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    print(f"{len(data['owner'])} sources across {len(data['defs'])} libraries "
          f"-> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
