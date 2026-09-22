# Apple device shells

Both Apple shells — the iOS app on an iPhone and the sandboxed native macOS
app — are thin adapters over the shared `apple/DataRoverKit` package and are
built from `apple/DataRover`. The iOS app's landscape shell follows Figma
frame 572:788 and uses its exported logo and
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
  storage and package staging, save-status decoding (`SaveState` maps the
  core's `datarover_save_status` to idle/pending/saved/failed), the
  support-path layout, and `ROMPin`, the pinned-image check the macOS app
  performs on File ▸ Import ROM… (the retired launcher's contract). `swift
  test` covers this target (18 tests in 6 suites).
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

## macOS app

The macOS app target (`Mac/`, scheme `DataRoverMac`, product
`DataRover.app`, bundle id `com.example.DataRover.mac`) is the same kind of
adapter: `DataRoverMacApp.swift` (entry point, menu bar, settings scene,
welcome state), `MetalFramebufferView.swift` and `PointerPenView.swift` (the
`NSViewRepresentable` wrappers around the shared presenter and pen router),
`MacHostHooks.swift` (`ProcessInfo.beginActivity` as the save assertion), and
`SupportPaths+macOS.swift` (the sandboxed support root). It holds no
emulation logic and imports everything else from the package.

Build and run from the repo root:

```sh
tools/build_mac_swift_app.sh && open build/DataRover.app
```

The script builds the `DataRoverMac` scheme for
`platform=macOS,arch=arm64` with the developer's default DerivedData, stages
the product at
`build/DataRover.app` — the path the retired SDL launcher bundle used to
occupy — and ad-hoc signs the staged copy (`codesign --force -s -`). In Xcode,
open `apple/DataRover/DataRover.xcodeproj` and run the `DataRoverMac` scheme
directly. `xcodegen generate && python3 scripts/inject_mame_sources.py`
reproduces the committed project whenever `project.yml` changes.

Beyond the package's Metal, AppKit and SwiftUI imports (which Swift
autolinking covers without target flags), the only frameworks the target names
explicitly are Carbon, CoreAudio, CoreFoundation and CoreMIDI.

### State and the sandbox

The app is sandboxed (`com.apple.security.app-sandbox`, plus
`files.user-selected.read-write` for the open panels and
`com.apple.security.network.client`), so its support root lives inside its
container:

```
~/Library/Containers/com.example.DataRover.mac/Data/Library/Application Support/DataRover
```

It holds the same `roms/`, `nvram/`, `cfg/` and `packages/` layout the iOS app
keeps under its container's `Documents`; Settings ▸ Support folder shows the
path and reveals it in Finder. The retired unsandboxed bundle kept its state
in `~/Library/Application Support/DataRover`, which a sandboxed process cannot
see at all, so there is deliberately no migration: the first launch boots
fresh and imports the ROM through File ▸ Import ROM…. The old tree is left
untouched.

### Menus and the pen

The File menu carries Import ROM…, Install Package… (⇧⌘I), Save State (⌘S) and
Restart, and the View menu a Pause/Resume toggle; a Settings scene shows the
support folder. The session items act on the running window through its
focused value, so they stay disabled until a ROM is loaded and the emulator
view exists. Import ROM… applies the same pinned-image check the retired
launcher performed.

The guest screen takes a pointer pen: mouse down/drag/up become pen events,
and the Pen tracking view is flipped so the guest's top-down rows line up with
the AppKit origin. The physical left and right ⌥ keys are the guest's two
Option buttons — macOS reports them as separate key codes (58 left, 61 right),
and a local `flagsChanged` monitor maps them onto the shared session's
`option` calls.

### Package installs on both platforms

Both apps install a picked `.pkg` through the core's in-process PCLink
channel: the shared `EmulatorSession.installPackage` stages the file and calls
`datarover_install_package` in-process while the emulation worker keeps
running. That is the only channel either app uses — iOS cannot create the
desktop PTY slave, and the macOS app no longer depends on the retired
launcher's PTY announcement/scraper. The guest speaks first, so the transfer
starts when the user opens the Storeroom computer on the DataRover; the
shared banner and sheet say so on both platforms.

`DataRover.xcodeproj` is generated, not hand-maintained. From
`apple/DataRover`, `xcodegen generate && python3 scripts/inject_mame_sources.py`
reproduces the committed `project.pbxproj`: the injector adds the MAME sources
listed in `Core/file-list.txt` and strips the `-ObjC` that xcodegen auto-adds
to the app target, so the committed file is exactly what the pipeline emits.

Stage 1 moved these out of the app target (the right column is relative to
`apple/DataRoverKit/`; the left column is the pre-stage-1 path, renamed to
`apple/` by this stage's first commit):

| Before (pre-stage-1 path) | After |
|---|---|
| `CoreBridge.h` | `Sources/CDataRoverABI/include/CoreBridge.h` |
| `CoreBridge.swift` | `Sources/DataRoverShell/CoreHandle.swift` |
| `ToolbarView.swift` | `Sources/DataRoverShell/DeviceShellView.swift` |
| the Metal coordinator inside `EmulatorView.swift` | `Sources/DataRoverShell/FramebufferPresenter.swift` |
| the pen geometry and pen routing inside `TouchPenView.swift` | `Sources/DataRoverKit/GuestGeometry.swift`, `Sources/DataRoverShell/PenRouter.swift` |
| the ROM store and package staging from `DataRoverApp.swift` | `Sources/DataRoverKit/ROMStore.swift`, `Sources/DataRoverKit/PackageStaging.swift` |
| the session, save-status decoding and ABI wrappers from `CoreBridge.swift` | `Sources/DataRoverShell/EmulatorSession.swift`, `Sources/DataRoverKit/SaveState.swift` |
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

The app's acceptance command runs from `apple/DataRover` against a booted
iPhone 17 Pro simulator:

```sh
cd apple/DataRover
xcodegen generate && python3 scripts/inject_mame_sources.py
DEV=<udid of the booted iPhone 17 Pro>
rm -f "$(xcrun simctl get_app_container "$DEV" com.example.DataRover data)/Documents/cfg/session.sta"
xcrun simctl bootstatus "$DEV" -b
xcodebuild test -project DataRover.xcodeproj -scheme DataRover \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

`UITests/TouchAcceptanceTests.swift` presses the guest's touch-gated startup
screen and then its three calibration targets, and checks that the guest
repaints after each press; the guest only advances that flow when the pen
lands where it is waiting, so reaching the workbench is the proof. Two
prerequisites:

- The checkpoint delete above is required, not optional: a restored checkpoint
  leaves the guest rendering but ignoring the pen, so a second run without it
  starts from the restored guest and fails.
- The ROM fixture must be in the container at
  `Documents/roms/datarover840/magiccap-usa.image`. Without it the app shows
  its "Import ROM…" empty state and the test skips instead of failing.

The pen press is geometry-independent, but the three calibration targets are
fractions of the iPhone 17 Pro's 874×402 pt landscape window: the test skips
the calibration phase on any other window size rather than claim a workbench
arrival it did not verify.

The fixture used for verification is
`~/Library/Application Support/DataRover/roms/datarover840/magiccap-usa.image`,
SHA-256 `94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b`.
The macOS app takes the same image, either through File ▸ Import ROM… or by
copying it into the app container's `roms/datarover840/`.

## Known issues

Two defects in the emulated core surfaced while these layouts were being
verified. Neither is caused by the package extraction and neither is fixed
here; both are core-side, not app- or package-side.

- **Restart segfaults during soft reset.** Choosing Restart in a shell — the
  iOS logo menu or the macOS File menu — crashes inside MAME's
  `sound_stream`/`dmadac` path while the machine resets. The ABI call
  (`datarover_restart`) only sets a flag and wakes the worker, and the crash
  log has no frame from the app or the package. The fork's headless controls
  regression does drive `datarover_restart`
  (`src/libdatarover/tests/controls.cpp:30`) and passes, linked against the
  app's own `libDataRoverCore.a` — `PASS controls, pause, checkpoint, restart,
  resume and corrupt-save fallback` — so the crash is specific to the app's
  configuration or state, not to either platform, and its cause is not yet
  explained.
- **A saved checkpoint suppresses guest pen input.** With a `cfg/session.sta`
  checkpoint present in the app's support root, the guest renders but ignores
  the pen: it restores into a state where the touch-gated startup and
  calibration screens never run. A checkpoint is written on every
  pause/background entry and every 60 seconds while running, so a normal
  session leaves one behind — this is why the iOS acceptance command above
  deletes `Documents/cfg/session.sta` first. Removing the file restores pen
  input.
