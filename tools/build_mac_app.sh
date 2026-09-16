#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAME_DIR="${MAME_DIR:-$REPO_ROOT/../mame}"
BIN="$MAME_DIR/datarover"
APP="$REPO_ROOT/build/DataRover.app"
CONTENTS="$APP/Contents"

[[ -x "$BIN" ]] || { printf 'error: datarover binary not found at %s\n' "$BIN" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$CONTENTS/Resources"
cp "$REPO_ROOT/packaging/macos/Info.plist" "$CONTENTS/Info.plist"
cp "$BIN" "$CONTENTS/MacOS/datarover"
cp "$REPO_ROOT/packaging/macos/launcher.sh" "$CONTENTS/MacOS/DataRover"
chmod +x "$CONTENTS/MacOS/DataRover"
printf 'staged %s\n' "$APP"
