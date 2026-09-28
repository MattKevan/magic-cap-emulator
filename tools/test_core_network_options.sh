#!/usr/bin/env bash
# Exercise the built macOS core library's create options with isolated state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAME_DIR="${MAME_DIR:-$ROOT/../mame}"
: "${CORE_LIBRARY:?Set CORE_LIBRARY to the built libDataRoverCoreMac.a}"
: "${ROM_PATH:?Set ROM_PATH to your Magic Cap ROM image}"
SCRATCH="$(mktemp -d /tmp/datarover-network-options.XXXXXX)"
DEPS="$ROOT/build/apple-network-deps/macosx/lib"
clang++ -std=c++20 -I "$MAME_DIR/src/libdatarover" \
  "$MAME_DIR/src/libdatarover/tests/network_options.cpp" "$CORE_LIBRARY" \
  "$DEPS/libslirp.a" "$DEPS/libglib-2.0.a" "$DEPS/libintl.a" "$DEPS/libpcre2-8.a" \
  -framework Foundation -framework CoreMIDI -framework AudioToolbox \
  -framework CoreAudio -framework Carbon -framework Security \
  -framework SystemConfiguration -liconv -lresolv -o "$SCRATCH/network_options"
python3 - "$SCRATCH/network_options" "$ROM_PATH" "$SCRATCH/state" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=90).returncode)
except subprocess.TimeoutExpired:
    sys.exit("FAIL network options exceeded 90 seconds")
PY
