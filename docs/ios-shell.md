# iOS device shell

The landscape shell follows Figma frame 572:788 and uses its exported logo and
Option artwork. Hold either Option control while touching the guest screen;
both controls feed the same emulated hardware input, with independent releases.
The logo opens Save state, Restart, and Load package.

The core runs at real-time speed with MAME throttling and sleeping enabled.
The Metal view checks for changed frames at 30 Hz, and stops its display link
while paused. Opening the menu or leaving the app pauses the emulation worker.
Actual device heat still needs a sustained physical-device check.

A complete MAME checkpoint is atomically replaced on background/menu entry,
manual save, clean shutdown and every 60 seconds while running. iOS background
saving uses a bounded background task. Relaunch restores the checkpoint;
invalid saves fall back to booting from NVRAM. Force termination before a save
finishes can lose changes since the previous checkpoint. Saves are tied to the
current core's state format; NVRAM fallback may contain older data.

Package import copies the selected file into Documents/packages and then
installs it into the running guest through the core's in-process PCLink
channel, showing progress and the guest's verdict. The core prefers that
channel over the desktop PTY slave, which the iOS sandbox cannot create.

The guest speaks first, so the transfer starts when the user opens the
Storeroom computer on the DataRover; the app says so in its install banner and
in the package sheet. The core seeds the Magic Bus accessory configuration on
first boot, because without it the guest never offers a link at all.

`src/libdatarover/tests/install.cpp` (in the MAME fork) is the regression: it
drives the same taps the CLI harness uses, starts the host install before the
Storeroom-computer tap, and passes `PASS in-process PCLink package install`
with the package counted in the guest's Storeroom storage.

## Shared package layout

The app's portable code lives in `apple/DataRoverKit`, a local SwiftPM package
with three targets:

- `CDataRoverABI` — the core's C ABI as declared to Swift: `CoreBridge.h`, a
  nullability-annotated copy of the fork's
  `src/libdatarover/datarover_core.h`, plus a short Objective-C translation
  unit that compiles it into an importable module. `tools/check_core_abi.py`
  gates the copy: every function it declares must exist in the fork's header
  with the same parameter and return types (the copy is a deliberate subset,
  so fork-only functions are ignored). The Swift layer never includes the fork
  header, so this check is what keeps the hand copy from drifting.
- `DataRoverKit` — pure logic, no platform UI: guest screen geometry, ROM
  storage and package staging, save-state decoding, the support-path layout,
  and `ROMPin`, the pinned-image check the macOS launcher already performs.
  `swift test` covers this target (18 tests in 6 suites).
- `DataRoverShell` — the shared shell: the Swift spelling of the ABI
  (`CoreHandle`), the emulator session lifecycle (`EmulatorSession`,
  `HostHooks`), the Metal framebuffer presenter, the pen router, the SwiftUI
  device shell, and the artwork under `Sources/DataRoverShell/Resources`.

The iOS app target is a thin adapter over that package: `DataRoverApp.swift`
(entry point, ROM import, the container's Documents directory as the support
root), `EmulatorView.swift` and `TouchPenView.swift` (the `UIViewRepresentable`
wrappers around the shared presenter and pen router), `HostHooks.swift` (the
iOS background task that lets a checkpoint save finish), the app icon and
`Info.plist`.

`DataRover.xcodeproj` is generated, not hand-maintained. From
`apple/DataRover`, `xcodegen generate && python3 scripts/inject_mame_sources.py`
reproduces the committed `project.pbxproj`: the injector adds the MAME sources
listed in `Core/file-list.txt` and strips the `-ObjC` that xcodegen auto-adds
to the app target, so the committed file is exactly what the pipeline emits.

Stage 1 moved these out of the app target (the right column is relative to
`apple/DataRoverKit/`):

| Before (`ios/DataRover/App/`) | After |
|---|---|
| `CoreBridge.h` | `Sources/CDataRoverABI/include/CoreBridge.h` |
| `CoreBridge.swift` | `Sources/DataRoverShell/CoreHandle.swift` |
| `ToolbarView.swift` | `Sources/DataRoverShell/DeviceShellView.swift` |
| the Metal coordinator inside `EmulatorView.swift` | `Sources/DataRoverShell/FramebufferPresenter.swift` |
| the pen geometry and pen routing inside `TouchPenView.swift` | `Sources/DataRoverKit/GuestGeometry.swift`, `Sources/DataRoverShell/PenRouter.swift` |
| the ROM store and package staging from `DataRoverApp.swift` | `Sources/DataRoverKit/ROMStore.swift`, `Sources/DataRoverKit/PackageStaging.swift` |
| the session, save-state decoding and ABI wrappers from `CoreBridge.swift` | `Sources/DataRoverShell/EmulatorSession.swift`, `Sources/DataRoverKit/SaveState.swift` |
| `Assets.xcassets` | `Sources/DataRoverShell/Resources/Assets.xcassets` |

## Clock investigation

Dino's RTC is a 40-bit counter at 32,768 Hz, not an absolute Unix timestamp.
The existing driver stores host time alongside RTC NVRAM and can advance the
counter by elapsed host time on a warm boot. Full checkpoint restore currently
restores the counter as saved, so time spent paused is not added. Setting the
Magic Cap calendar to the iPhone date requires identifying the guest calendar
base/setting interface; directly writing Unix seconds into the RTC is wrong.
Absolute phone-clock synchronization is not implemented in this change.

## Validation

Headless controls regression covers pause CPU usage, paused frame stability,
checkpoint creation, restart, reload, corrupt saves and shutdown while paused.
The iPhone 16 / iOS 18.5 simulator was used for visual comparison and logo-menu
save/restart checks. Backgrounding, termination and relaunch also restored
the same Magic Cap screen. iPad / iOS 27 simulator orientation needs further validation:
its captured surface appeared portrait and clipped. Guest-visible Option chords
and sustained device temperature require a physical-device check.

The app's acceptance command is `xcodebuild test -scheme DataRover`, run from
`apple/DataRover`. `UITests/TouchAcceptanceTests.swift` presses the guest's
touch-gated startup screen and then its three calibration targets, and checks
that the guest repaints after each press; the guest only advances that flow
when the pen lands where it is waiting, so reaching the workbench is the
proof. It has two prerequisites:

- Delete the app container's checkpoint first, or the guest restores into a
  state that renders but ignores the pen:

  ```sh
  rm -f "$(xcrun simctl get_app_container <udid> com.example.DataRover data)/Documents/cfg/session.sta"
  ```

- The ROM fixture must be in the container at
  `Documents/roms/datarover840/magiccap-usa.image`. Without it the app shows
  its "Import ROM…" empty state and the test skips instead of failing.

The fixture used for verification is
`~/Library/Application Support/DataRover/roms/datarover840/magiccap-usa.image`,
SHA-256 `94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b`.

## Known issues

Two defects in the emulated core surfaced while this layout was being
verified. Neither is caused by the package extraction and neither is fixed
here; both are core-side, not app- or package-side.

- **Restart segfaults during soft reset.** Tapping Restart crashes inside
  MAME's `sound_stream`/`dmadac` path while the machine resets. The ABI call
  (`datarover_restart`) only sets a flag and wakes the worker, and the crash
  log has no frame from the app or the package. No regression under `tests/`
  drives a core restart, so nothing guards that path.
- **A saved checkpoint suppresses guest pen input.** With
  `Documents/cfg/session.sta` present the guest renders but ignores the pen:
  it restores into a state where the touch-gated startup and calibration
  screens never run. A checkpoint is written on every pause/background entry
  and every 60 seconds while running, so a normal session leaves one behind —
  this is why the acceptance command above deletes it first. Removing the file
  restores pen input.
