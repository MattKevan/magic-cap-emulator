#!/usr/bin/env bash
# Exercise the actual native worker and driver; observer is compiled only here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAME_DIR="${MAME_DIR:-$ROOT/../mame}"
: "${CORE_LIBRARY:?Set CORE_LIBRARY to the built libDataRoverCoreMac.a}"
: "${CORE_BUILD_ARGUMENTS:?Set CORE_BUILD_ARGUMENTS to the Xcode C++ common-args.resp}"
: "${ROM_PATH:?Set ROM_PATH to your Magic Cap ROM image}"
SCRATCH="$(mktemp -d /tmp/datarover-power-wake.XXXXXX)"
DEPS="$ROOT/build/apple-network-deps/macosx/lib"
clang++ @"$CORE_BUILD_ARGUMENTS" -c "$MAME_DIR/src/libdatarover/tests/power_wake.cpp" -o "$SCRATCH/test.o"
clang++ "$SCRATCH/test.o" "$CORE_LIBRARY" \
  "$DEPS/libslirp.a" "$DEPS/libglib-2.0.a" "$DEPS/libintl.a" "$DEPS/libpcre2-8.a" \
  -framework Foundation -framework CoreMIDI -framework AudioToolbox \
  -framework CoreAudio -framework Carbon -framework Security \
  -framework SystemConfiguration -liconv -lresolv -o "$SCRATCH/power_wake"
printf 'Regression artifacts: %s\n' "$SCRATCH"
python3 - "$SCRATCH/power_wake" "$ROM_PATH" "$SCRATCH/state" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run(sys.argv[1:], timeout=120)
except subprocess.TimeoutExpired:
    sys.exit("FAIL power wake regression exceeded 120 seconds")
sys.exit(result.returncode)
PY
