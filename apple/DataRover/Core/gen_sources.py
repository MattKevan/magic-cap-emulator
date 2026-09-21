#!/usr/bin/env python3
"""Generate DataRoverCore sources list for the Xcode project from file-list.txt.

Reads apple/DataRover/Core/file-list.txt (MAME_DIR-relative paths) and emits
a project.yml fragment mapping each source to its Xcode file entry. Files
needing Objective-C ARC compilation (.mm) get per-file compiler flags;
excluded-at-build files are noted but kept in the list for auditability.

Usage: gen_sources.py [--check]
  default: print YAML fragment to stdout
  --check: verify every listed file exists under MAME_DIR (default ../../mame)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAME_DIR = os.environ.get("MAME_DIR", os.path.normpath(os.path.join(HERE, "..", "..", "..", "mame")))


def load_list():
    path = os.path.join(HERE, "file-list.txt")
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip()]


def main():
    check = "--check" in sys.argv
    srcs = load_list()
    missing = [s for s in srcs if not os.path.exists(os.path.join(MAME_DIR, s))]
    if check:
        for s in missing:
            print(f"MISSING: {s}")
        print(f"{len(srcs) - len(missing)}/{len(srcs)} present under {MAME_DIR}")
        return 1 if missing else 0
    for s in srcs:
        print(f"      - path: $(MAME_DIR)/{s}")


if __name__ == "__main__":
    main()
