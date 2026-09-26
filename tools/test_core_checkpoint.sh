#!/usr/bin/env bash
# Exercise the app's actual macOS core library with isolated, disposable state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAME_DIR="${MAME_DIR:-$ROOT/../mame}"
: "${CORE_LIBRARY:?Set CORE_LIBRARY to the built libDataRoverCoreMac.a}"
: "${ROM_PATH:?Set ROM_PATH to your Magic Cap ROM image}"
SCRATCH="$(mktemp -d /tmp/datarover-checkpoint.XXXXXX)"
DEPS="$ROOT/build/apple-network-deps/macosx/lib"
clang++ -std=c++20 -I "$MAME_DIR/src/libdatarover" \
  "$MAME_DIR/src/libdatarover/tests/checkpoint.cpp" "$CORE_LIBRARY" \
  "$DEPS/libslirp.a" "$DEPS/libglib-2.0.a" "$DEPS/libintl.a" "$DEPS/libpcre2-8.a" \
  -framework Foundation -framework CoreMIDI -framework AudioToolbox \
  -framework CoreAudio -framework Carbon -framework Security \
  -framework SystemConfiguration -liconv -lresolv -o "$SCRATCH/checkpoint"
printf 'Regression artifacts: %s\n' "$SCRATCH"
# Bound shutdown too: a broken core may block in datarover_destroy().
python3 - "$SCRATCH/checkpoint" "$ROM_PATH" "$SCRATCH/state" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run(sys.argv[1:], timeout=90)
except subprocess.TimeoutExpired:
    sys.exit("FAIL checkpoint regression exceeded 90 seconds")
sys.exit(result.returncode)
PY
