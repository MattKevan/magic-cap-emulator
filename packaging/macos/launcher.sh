#!/usr/bin/env bash
set -euo pipefail
APP_SUPPORT="$HOME/Library/Application Support/DataRover"
ROMDIR="$APP_SUPPORT/roms/datarover840"
ROM="$ROMDIR/magiccap-usa.image"
WANT_SHA="94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b"
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/datarover-bin"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$ROMDIR" "$APP_SUPPORT/nvram" "$APP_SUPPORT/cfg"

if [[ ! -f "$ROM" ]] || [[ "$(sha256_of "$ROM")" != "$WANT_SHA" ]]; then
  pick="$(osascript -e 'POSIX path of (choose file with prompt "Select your MagicCap-USA.image ROM")')"
  cp "$pick" "$ROM"
  [[ "$(sha256_of "$ROM")" == "$WANT_SHA" ]] || { osascript -e 'display alert "ROM checksum mismatch" message "That file is not the pinned MagicCap-USA.image."'; exit 1; }
fi

mode="${1:-run}"
extra=()
case "$mode" in
  fresh) mv "$APP_SUPPORT/nvram" "$APP_SUPPORT/nvram.bak.$(date +%s)" 2>/dev/null || true; mkdir -p "$APP_SUPPORT/nvram"; shift || true;;
  --) shift;;
esac
if [[ "${1:-}" == "--" ]]; then shift; fi
extra=("$@")

export SDL_VIDEO_HIGHDPI_DISABLED=1
exec "$BIN" datarover840 \
  -rompath "$APP_SUPPORT/roms" \
  -cfg_directory "$APP_SUPPORT/cfg" \
  -nvram_directory "$APP_SUPPORT/nvram" \
  -window -skip_gameinfo \
  -ui_active \
  -nokeepaspect \
  -view LCD \
  -lightgun -lightgun_device lightgun \
  ${extra[@]+"${extra[@]}"}
