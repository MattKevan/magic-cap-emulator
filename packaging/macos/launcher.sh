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
APP_LOGS="$APP_SUPPORT/logs"
APP_RUN="$APP_SUPPORT/run"
LOG="$APP_LOGS/last-boot.log"
PTY_FILE="$APP_RUN/pclink-pty"
mkdir -p "$APP_LOGS" "$APP_RUN"

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

# PCLink PTY contract (see tools/pclink_send.py and the File → Install
# Package… menu handler): the menu needs the path MAME announces on stdout
# as ":rs2321:pty PTY: <path>" (same PTY_PATTERN as
# tools/pclink_regression.py:36), plus the repo root holding
# tools/pclink_send.py.  The repo root is known here; the PTY path is not
# (the device only exists after the emulator starts), and exec preserves
# the environment but freezes it — a pre-exec export cannot carry a
# post-exec value.  So:
#   * export MAGIC_CAP_EMULATOR_ROOT now (best effort; the menu falls back
#     to the fork-adjacent checkout layout when it is absent);
#   * clear any inherited DATAROVER_PCLINK_PTY (a stale slave path from an
#     older boot must never win) and remove last boot's run file;
#   * tee emulator output to $APP_SUPPORT/logs/last-boot.log while a
#     disowned background scraper publishes the announced path to
#     $APP_SUPPORT/run/pclink-pty.  The subshell is a separate process, so
#     it survives the exec below; the menu reads the env var first, then
#     the run file.
REPO_ROOT=""
for CANDIDATE in "$HERE/../.." "$HERE/../../../.." "$HERE/../../../../../magic-cap-emulator"; do
  if [[ -f "$CANDIDATE/tools/pclink_send.py" ]]; then
    REPO_ROOT="$(cd "$CANDIDATE" && pwd)"
    break
  fi
done
if [[ -n "$REPO_ROOT" ]]; then export MAGIC_CAP_EMULATOR_ROOT="$REPO_ROOT"; fi
unset DATAROVER_PCLINK_PTY || true
rm -f "$PTY_FILE"
(
  tries=0
  while [[ $tries -lt 480 ]]; do
    if grep -a -q ':rs2321:pty PTY:' "$LOG" 2>/dev/null; then
      pty="$(grep -a -o ':rs2321:pty PTY: *[^[:space:]]*' "$LOG" 2>/dev/null | head -n 1 | sed 's/.*PTY: *//')"
      if [[ -n "${pty:-}" ]]; then printf '%s\n' "$pty" > "$PTY_FILE"; break; fi
    fi
    sleep 0.25
    tries=$((tries + 1))
  done
) &
exec "$BIN" datarover840 \
  -rompath "$APP_SUPPORT/roms" \
  -cfg_directory "$APP_SUPPORT/cfg" \
  -nvram_directory "$APP_SUPPORT/nvram" \
  -window -skip_gameinfo \
  -ui_active \
  -nokeepaspect \
  -view LCD \
  -lightgun -lightgun_device lightgun \
  -rs2321 pty \
  ${extra[@]+"${extra[@]}"} > >(tee "$LOG") 2>&1
