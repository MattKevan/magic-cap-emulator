# DataRover cross-platform (iOS + macOS) app — design

Scope: turn the iOS-only Xcode project into a two-platform Apple app —
shared core package, thin iOS and macOS layers, native macOS shell.

This supersedes the *Mac frontend* section of
[`2026-09-17-shared-core-design.md`](2026-09-17-shared-core-design.md).
That spec's core/frontend split and its rejection of portable-SDL-for-both
still hold; what changes is the Mac frontend's shape. It planned a SwiftUI
shell alongside the SDL frontend in a not-yet-existing project. Since then
the iOS shell shipped and the SDL path stayed the bash-launcher bundle, so
the Mac frontend is realized here as a second app target in the same
project instead.

## Goal

Add a macOS build target so one codebase produces both apps:

- the emulator core built for both platforms from the same sources and the
  same configuration,
- one shared Swift layer for session, geometry and shell UI,
- thin per-platform layers that own only what genuinely differs: pointer
  versus touch, window versus screen chrome, menus, entitlements.

## Current state (evidence)

| Claim | Evidence |
|---|---|
| The core ABI is already portable | `datarover_core.h` declares 17 functions; `datarover_core.cpp` is POSIX/libc++ with its own `core_headless_osd` and no `TARGET_OS` (`<mame>/src/libdatarover/`) |
| The Xcode core target's iOS-specificity is build glue only | `project.yml` `platform: iOS`; `Core/ios_compat/Carbon/Carbon.h` and `Core/ios_compat/CoreAudio/HostTime.h` exist to satisfy `osdlib_macosx.cpp:29` (`#include <Carbon/Carbon.h>`) and `pmmacosxcm.c` (`AudioGetCurrentHostTime`); `Core/datarover_carboncore_stubs.cpp` defines `Pasteboard*`/`kUTType*` |
| macOS-only TUs are already in the file list | `Core/file-list.txt:287-288` (PortMidi `pm_mac`/`porttime`), `:1076` (`osdlib_macosx.cpp`) |
| The Swift layer is mostly portable | 846 lines; `UIKit` appears once (`App/CoreBridge.swift:61`, two `UIApplication` call sites); `UIViewRepresentable` in `App/EmulatorView.swift` and `App/TouchPenView.swift`; `requestLandscape`/`statusBarHidden` in `App/DataRoverApp.swift`; `App/ToolbarView.swift` is pure SwiftUI |
| macOS today is a separate SDL binary | `packaging/macos/launcher.sh` execs `$MAME_DIR/datarover` (stock SDL3 build) with `-rs2321 pty`; `tools/build_mac_app.sh` stages `build/DataRover.app` |

Consequences of the last row: the macOS bundle uses the PTY PCLink path and
a bash/osascript first-run wizard, both of which the iOS shell has already
replaced with the in-process channel (`datarover_install_package_named`)
and a native importer.

## Decisions

1. **Deployment floors: iOS 26.0 and macOS 26.0.** The iOS app moves from
   16.0 to 26.0, so iOS 16–25 devices are dropped. The Liquid Glass
   `App/AppIcon.icon` becomes native on both platforms.
2. **macOS keeps the shared device shell** (bezel + Option rails, Figma
   frame 572:788) and gains a menu bar. Platform layer = pointer events,
   window sizing, `NSMenu` commands.
3. **macOS packaging: App Sandbox + hardened runtime**, ad-hoc signed
   locally, ready for a Developer ID later. No migration of the existing
   `~/Library/Application Support/DataRover/` state: under sandbox it cannot
   even be probed, so the app boots fresh in its container and the ROM is
   re-imported by hand. The current NVRAM/save state is forfeited.
4. **Two explicit core targets**, not one multi-platform target. xcodegen's
   `supportedDestinations` silently drops `[sdk=…]` conditional settings and
   per-platform deployment targets (verified), which is the worst failure
   mode for a hand-tuned build; and the per-platform differences are exactly
   the fragile ones.
5. **Core configuration is identical on both platforms** — same per-file
   `COMPILER_FLAGS`, same `-D` set (`FORCE_DRC_C_BACKEND=1`,
   `DATAROVER_IOS_NO_JIT_FLUSH=1`, `NDEBUG`). One behavior surface; the C
   backend already runs at real-time speed under MAME throttling, so there
   is nothing to gain from a macOS-only DRC/asmjit JIT.
6. **Shared layer is a local SwiftPM package** with `DataRoverKit` (pure,
   `swift test`-able) and `DataRoverShell` (ABI + session + shared UI).
7. **Three stages:** extract, then macOS target, then retire the SDL
   launcher bundle and update docs.

## Architecture

### Build graph

| Target | Kind | Platform | Notes |
|---|---|---|---|
| `DataRoverCore` | static lib | iOS 26.0 | Existing target, name unchanged |
| `DataRoverCoreMac` | static lib | macOS 26.0 | Same sources minus `Core/datarover_carboncore_stubs.cpp` |
| `DataRover` | app | iOS 26.0 | Thin |
| `DataRoverMac` | app | macOS 26.0 | Thin, sandboxed |
| package `DataRoverKit` | SwiftPM | iOS 26.0 / macOS 26.0 | Both apps depend on it |

`DataRoverCoreMac` source list = `Core/file-list.txt` minus the iOS stub TU,
whose `Pasteboard*`/`kUTType*` definitions would collide with the real
Carbon symbols at link time.

Per-platform core settings, macOS column:

- `HEADER_SEARCH_PATHS` **without** `$(SRCROOT)/Core/ios_compat`
  (`project.yml:60`). Leaving it in shadows the real
  `<Carbon/Carbon.h>` with the iOS stub — a silent, build-order-dependent
  failure.
- `MACOSX_DEPLOYMENT_TARGET = 26.0`.
- Link flags for the real frameworks the iOS shims fake: `Carbon` (Pasteboard
  symbols, `osdlib_macosx.cpp`), `CoreAudio` (`AudioGetCurrentHostTime`,
  `pmmacosxcm.c`) and `CoreFoundation` (`ptmacosx_cf.c`), plus `-lc++` and
  `-framework CoreMIDI` as on iOS. A static library does not propagate its
  frameworks, so the Mac app target carries the link flags too.
- Per-file `COMPILER_FLAGS` are byte-identical to iOS: the flags come from
  the fork's GENie lib map, which is platform-neutral.

`scripts/inject_mame_sources.py` grows a per-target loop: one source list,
a per-target UUID namespace, and a per-target exclusion set. The documented
regeneration path stays `xcodegen generate && python3
scripts/inject_mame_sources.py`. `scripts/gen_ios_libmap.py` renames to
`gen_mame_libmap.py` — the map is platform-neutral and the `ios` name
becomes a lie.

Directory: `ios/` → `apple/`, because the tree now hosts both platforms.

```text
apple/DataRover/          DataRover.xcodeproj, App/, Mac/, Core/, scripts/, project.yml
apple/DataRoverKit/       Package.swift, Sources/, Tests/
```

The only live reference to the old path is a docstring in
`Core/gen_sources.py`; `docs/superpowers/**` keeps its recorded paths as
history.

### Package modules

`apple/DataRoverKit`, platforms `.iOS("26.0"), .macOS("26.0")`:

| Module | Depends on | Contents |
|---|---|---|
| `CDataRoverABI` (C) | — | `CoreBridge.h` moved from `App/`, plus a trivial `shim.c`. Declarations only — the property that the app never includes the fork header (and therefore needs no MAME header search paths) is preserved |
| `DataRoverKit` (Swift) | — | Pure logic: `GuestGeometry` (aspect-fit letterbox → guest coordinates), `SupportPaths` (root injected by the platform), `ROMStore` (exact-layout preference, import copy), `PackageStaging`, ROM checksum verification, save-status → message mapping. No UIKit/AppKit, no SwiftUI, no ABI — so `swift test` links and runs without the core |
| `DataRoverShell` (Swift) | Kit, CDataRoverABI | ABI wrappers, `EmulatorSession`, `HostHooks`, shared SwiftUI (`DeviceShellView`, `OptionControl`, `EmulatorControlsSheet`, `InstallStatusBanner`), portable `FramebufferPresenter` (MTKViewDelegate: 2bpp expansion, persistent texture/pipeline/sampler, aspect-fit draw) and `PenRouter` |

**No conditional compilation inside the package.** A SwiftUI representable
must be either `UIViewRepresentable` or `NSViewRepresentable`, so the leaf
adapters live in the app targets — they are the thin layers the design is
about. `HostHooks` abstracts the one genuinely platform-specific session
concern: iOS takes a `UIApplication` background task while saving, macOS
calls `NSProcessInfo.beginActivity(options: [.suddenTerminationDisabled,
.automaticTerminationDisabled])`.

Shared artwork follows the shared views. `App/Assets.xcassets`
(`GeneralMagicLogo`, `OptionFace`, `OptionRing`) moves into
`DataRoverShell` as a processed resource
(`Sources/DataRoverShell/Resources/Assets.xcassets`) and the shell loads it
with `Image(…, bundle: .module)`, so neither app target has to know about
the device-shell artwork. The asset catalog has no `AppIcon` set — the
Liquid Glass icon is the separate `App/AppIcon.icon` document, referenced by
each app target individually.

```text
apple/DataRover/App/   DataRoverApp.swift   @main, scenePhase, landscape request, statusBarHidden
                       EmulatorView.swift   UIViewRepresentable → FramebufferPresenter
                       TouchPenView.swift   UITouch → PenRouter
                       HostHooks.swift      UIApplication background assertion
                       Info.plist, AppIcon.icon
apple/DataRover/Mac/   DataRoverMacApp.swift @main, Commands, Settings scene
                       EmulatorView.swift   NSViewRepresentable → FramebufferPresenter
                       PointerPenView.swift NSView mouse events → PenRouter
                       HostHooks.swift      NSProcessInfo activity
                       DataRover.entitlements, Info.plist (xcodegen-generated)
```

Code movement from the current files:

- `App/CoreBridge.swift` splits: ABI wrappers and `EmulatorSession` to
  Shell; the two `UIApplication` call sites to `HostHooks`.
- `App/EmulatorView.swift` loses only its representable shell; the
  2bpp/letterbox/Metal coordinator is already platform-neutral.
- `App/TouchPenView.swift` donates `guestCoords` to `GuestGeometry`, which
  makes the letterbox offset and the off-image rejection testable for the
  first time. The iOS view keeps the `UITouch` plumbing; macOS gets the
  `NSView` equivalent.
- `App/ToolbarView.swift` moves as-is (pure SwiftUI).
- `ROMStore` and `PackageImport` from `App/DataRoverApp.swift` move to Kit
  with the root URL injected.

Mac menu bar: File (Import ROM…, Install Package…, Save State, Restart),
View (Pause/Resume), plus a `Settings` scene that reveals the support
directory. The physical left/right ⌥ keys map to the two guest Option
buttons — macOS reports the sides separately, and it is the device's own
idiom. The shared shell still draws the rails.

`tools/check_core_abi.py` (new, small): verifies every declaration in
`CDataRoverABI/CoreBridge.h` matches `<mame>/src/libdatarover/datarover_core.h`
signature-for-signature. The header is a deliberate subset — the fork-only
`datarover_emulated_seconds` is ignored — and it is currently a hand copy,
which is a plausible drift bug now that two consumers exist.

### macOS packaging

- `Mac/DataRover.entitlements`: `com.apple.security.app-sandbox`,
  `com.apple.security.files.user-selected.read-write` (ROM and package
  import), `com.apple.security.network.client` (future EtherLink/slirp
  path). Hardened runtime (`-o runtime`), ad-hoc `codesign -s -`. No JIT
  entitlement: the C backend needs no writable-executable memory, which is
  what keeps a later Developer ID pass uneventful.
- `Mac/Info.plist` generated by xcodegen, with `LSApplicationCategoryType`
  and `NSHighResolutionCapable`. The iOS app keeps its hand-written
  `App/Info.plist`.
- `App/AppIcon.icon` is wired into the Mac target too, so the Liquid Glass
  icon and the `.icns` come from one document; `packaging/macos/DataRover.icns`
  retires.
- Bundle id `com.example.DataRover.mac`; iOS keeps `com.example.DataRover`,
  so per-platform provisioning and App Store records stay unambiguous.
- State root, supplied by the platform layer: iOS unchanged
  (`Documents/{roms,nvram,cfg,packages}`); macOS container
  `~/Library/Containers/com.example.DataRover.mac/Data/Library/Application Support/DataRover/{roms,nvram,cfg,packages,logs}`.
- Package installs use the in-process channel
  (`datarover_install_package_named`) on both platforms, exactly as iOS
  does. Sandboxing does not impede it: the open panel grants access to the
  picked file, and the guest transfer is in-process. That is why the iOS
  shell could drop the PTY path in the first place.

## Verification

Per stage, run the app — the repo's existing acceptance — rather than
asserting internals.

Stage 1 (extract): `swift test` green; iOS app builds and runs with
unchanged behavior: import ROM → calibration → workbench, Option chords,
save/restart, package install landing in the Storeroom.

Stage 2 (macOS): `codesign -d --entitlements` shows the expected set; the
sandboxed app boots the pinned ROM (`94785cb3…`, `docs/rom-layout.md`) from
its container; mouse drag produces a guest pen stroke; calibration
completes; Save State, Restart, and Install Package work; `swift test` still
green.

Stages 1 and 2 land independently: stage 1 is a pure refactor whose proof is
an unchanged iOS app, and stage 2 adds the Mac target on top. Each can be
planned as its own implementation plan.

Stage 3 (retire): the SDL CLI, its PTY contract, and every headless
regression are untouched — no core source or flag changes are in scope, so
they are outside the blast radius. Delete `packaging/macos/launcher.sh`,
`packaging/macos/Info.plist`, `packaging/macos/DataRover.icns`,
`tools/build_mac_app.sh`; add a script that builds `DataRoverMac` and
stages `build/DataRover.app`. Rename `docs/ios-shell.md` →
`docs/apple-shell.md` with a macOS section (including how to build and run
the app, which is undocumented today); update `PLAN.md` and the
"`tools/start_manual.sh` remains the normal interactive launcher" pointer at
`docs/mame-bringup.md:363`, which becomes the CLI path rather than the
default one.

Tests: `DataRoverKit` unit tests only, and only where a plausible bug would
fail them — letterbox geometry (corners, off-image rejection, clamping),
ROM store selection (exact layout preferred over a fallback match), package
staging (unique naming on collision), checksum verification, save-status
message mapping. Nothing asserts the SwiftUI layer, the Metal pipeline, or
the C ABI wiring.

## Out of scope

- A `datarover_key_event` ABI addition and host keyboard input (planned in
  `2026-09-17-ios-shell-design.md`, unaffected by this work).
- Networking on either platform (`docs/etherlink.md` paths).
- Developer ID signing, notarization, distribution.
- Any change to the MAME fork, the emulation core, or the regression suite.

## Accepted losses

- iOS 16–25 devices are dropped by the 26.0 floor.
- The macOS app cannot see the existing
  `~/Library/Application Support/DataRover/` state; the first boot in the
  container starts from calibration, and any installed packages or Magic Cap
  data in the old NVRAM are not carried over.
- `build/DataRover.app` changes meaning: from the SDL launcher bundle to the
  native macOS app at stage 3.