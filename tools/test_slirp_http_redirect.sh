#!/usr/bin/env bash
# Build and run the libslirp redirect test against the macOS dependency slice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/apple-network-deps/macosx"
SCRATCH="$(mktemp -d /tmp/datarover-slirp-redirect.XXXXXX)"
clang -std=c11 -I "$DEPS/include" "$ROOT/apple/DataRover/scripts/tests/slirp_http_redirect_test.c" \
  "$DEPS/lib/libslirp.a" "$DEPS/lib/libglib-2.0.a" "$DEPS/lib/libintl.a" "$DEPS/lib/libpcre2-8.a" \
  -framework Foundation -framework CoreMIDI -framework AudioToolbox -framework CoreAudio \
  -framework Carbon -framework Security -framework SystemConfiguration -liconv -lresolv \
  -o "$SCRATCH/slirp_http_redirect"
"$SCRATCH/slirp_http_redirect"
