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
cp "$REPO_ROOT/packaging/macos/DataRover.icns" "$CONTENTS/Resources/DataRover.icns"
cp "$BIN" "$CONTENTS/MacOS/datarover-bin"
cp "$REPO_ROOT/packaging/macos/launcher.sh" "$CONTENTS/MacOS/DataRover"
chmod +x "$CONTENTS/MacOS/DataRover"
printf 'staged %s\n' "$APP"
FW="$CONTENTS/Frameworks"
for lib in $(otool -L "$BIN" | awk '{print $1}' | grep -E 'libSDL'); do
  src="$lib"
  [[ -f "$src" ]] || src="$(brew --prefix sdl2)/lib/$(basename "$lib")"
  cp -n "$src" "$FW/" 2>/dev/null || cp "$src" "$FW/"
  install_name_tool -change "$lib" "@executable_path/../Frameworks/$(basename "$lib")" "$CONTENTS/MacOS/datarover-bin"
done
codesign --force --deep -s - "$APP"
codesign -vv "$APP"
