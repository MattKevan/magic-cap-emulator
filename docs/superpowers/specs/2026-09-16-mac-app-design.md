# DataRover macOS .app — design

Scope: local-use `.app` wrapper + first-run setup wizard. No emulator
changes, no distribution signing, no native UI beyond the wizard.

## Approach

Shell-launcher bundle. `Contents/MacOS/DataRover` (bash launcher) runs
first-run checks, then `exec`s the MAME `datarover` binary with the exact
`tools/start_manual.sh` flags. `exec` keeps a single Dock process.

Rejected: Platypus/Automator wrapper — opaque, untracked, worse wizard UX.

## Bundle layout

```text
DataRover.app/Contents/
  Info.plist                  CFBundleExecutable=DataRover, NSHighResolutionCapable
  MacOS/DataRover             launcher script (bash + osascript wizard)
  MacOS/datarover             MAME SUBTARGET=datarover build output
  Frameworks/SDL2.framework   bundled (or dylibs via install_name_tool @rpath)
  Frameworks/SDL2_ttf.framework
```

Build script `tools/build_mac_app.sh` assembles the bundle from a fresh
driver build. Build-time deps unchanged (`sdl2 sdl2_ttf` via brew); the
bundle embeds them so the .app has no runtime brew dependency.

## First-run wizard

State root: `~/Library/Application Support/DataRover/`.

1. Launcher checks `roms/datarover840/magiccap-usa.image` against SHA-256
   `94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b`
   (canonical checksum in `docs/rom-layout.md`).
2. Missing/mismatch → `osascript` file picker → copy into place → verify.
   Reject with retry on mismatch.
3. `mkdir -p nvram cfg`. Later launches skip the wizard.
4. ROM is never bundled (© General Magic, stays user-supplied).

## Runtime invocation

Same contract as `tools/start_manual.sh` today:

- `-rompath <support>/roms -cfg_directory <support>/cfg`
  `-nvram_directory <support>/nvram`
- `-view LCD -lightgun -lightgun_device lightgun -nokeepaspect -ui_active`
- `SDL_VIDEO_HIGHDPI_DISABLED=1` (Retina pen-axis fix)
- Launcher forwards argv (`fresh`, `-- <mame args>`) mirroring
  `start_manual.sh` modes; `fresh` moves `nvram/` aside instead of the
  asset-tree default.

Regressions untouched; the .app covers the interactive path only.

## Signing

Ad-hoc `codesign -s -` for local arm64 Gatekeeper acceptance. No paid
Developer ID, no notarization, no DMG in this scope.

## Verification

- Double-click boots to touch-calibration screen.
- Wizard rejects a bad ROM, accepts the pinned image.
- Relaunch preserves NVRAM; `fresh` resets.
- No automated tests: launcher is shell + osascript, verified by running it.
