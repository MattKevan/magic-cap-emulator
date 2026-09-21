#!/usr/bin/env python3
"""Check the package's ABI redeclaration against the fork's real header.

The Swift layer never includes the fork header (it has no MAME header search
paths), so CoreBridge.h is a hand copy and can drift. The copy is a
deliberate subset of the fork's declarations, so this checks one direction:
every function declared in CoreBridge.h must exist in the fork header with
the same parameter and return types. Fork-only functions (for example
datarover_emulated_seconds) are ignored.

Usage: python3 tools/check_core_abi.py [--mame-dir DIR]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
COPY = os.path.join(ROOT, "apple", "DataRoverKit", "Sources", "CDataRoverABI",
                    "include", "CoreBridge.h")
DEFAULT_MAME = os.path.normpath(os.path.join(ROOT, "..", "mame"))

DECL = re.compile(r"^\s*(?:const\s+)?[\w\s\*]+?\b(datarover_\w+)\s*\(([^;]*)\)\s*;", re.M)

# Swift-only annotations and pointer spacing are not ABI: the package copy is
# a nullability-annotated redeclaration, so comparing them verbatim would
# report drift on every declaration that legitimately carries `_Nullable`.
NULLABILITY = re.compile(r"\b_(?:Nullable|Nonnull|Null_unspecified)\b")


def normalise(text):
    """Collapse whitespace/annotation noise so only ABI text is compared."""
    text = NULLABILITY.sub(" ", text)
    text = re.sub(r"\s*\*\s*", "*", text)
    return re.sub(r"\s+", " ", text).strip()


def declarations(path):
    """Map function name -> (prefix, params) for every declaration in a header."""
    with open(path) as f:
        body = f.read()
    found = {}
    for match in DECL.finditer(body):
        prefix = normalise(body[match.start():match.start(1)])
        params = normalise(match.group(2))
        found[match.group(1)] = (prefix, params)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mame-dir", default=os.environ.get("MAME_DIR", DEFAULT_MAME))
    ap.add_argument("--fork-header", default=None,
                    help="path to the fork's datarover_core.h (default: <mame-dir>/src/libdatarover/datarover_core.h)")
    args = ap.parse_args()
    fork = args.fork_header or os.path.join(args.mame_dir, "src", "libdatarover", "datarover_core.h")
    if not os.path.exists(fork):
        print(f"fork header not found: {fork}", file=sys.stderr)
        return 2
    have = declarations(COPY)
    want = declarations(fork)
    problems = []
    for name, (prefix, params) in sorted(have.items()):
        if name not in want:
            problems.append(f"{name}: declared in CoreBridge.h but absent from the fork header")
            continue
        fprefix, fparams = want[name]
        if params != fparams:
            problems.append(f"{name}: parameter mismatch\n    copy: {params}\n    fork: {fparams}")
        if prefix != fprefix:
            problems.append(f"{name}: return type mismatch\n    copy: {prefix}\n    fork: {fprefix}")
    print(f"{len(have)} declarations checked against {fork}")
    for problem in problems:
        print(f"MISMATCH {problem}")
    if problems:
        return 1
    print("ABI copy matches the fork header")
    return 0


if __name__ == "__main__":
    sys.exit(main())
