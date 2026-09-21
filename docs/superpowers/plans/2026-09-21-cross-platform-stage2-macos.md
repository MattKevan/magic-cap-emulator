# Cross-platform DataRover — Stage 2: the macOS target — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sandboxed native macOS app that runs the same emulation core as the iOS app, sharing `DataRoverKit`/`DataRoverShell` and the DataRover device shell, with a macOS menu bar instead of the iOS touch/sheet chrome.

**Architecture:** A second static-library core target (`DataRoverCoreMac`) compiles the same 1159 sources with the same per-file flags, minus the iOS Carbon/Pasteboard stub TU and minus the `ios_compat` include path that would shadow the real `<Carbon/Carbon.h>`. A thin `DataRoverMac` app target supplies the four platform leaf files (entry + `Commands`/`Settings`, `NSViewRepresentable` framebuffer host, pointer pen view, `NSProcessInfo` host hooks) plus entitlements and a generated Info.plist. The SDL launcher bundle is retired only after the new app is proven at parity.

**Tech Stack:** xcodegen 2.45.4, SwiftPM local package (from stage 1), AppKit/SwiftUI, MetalKit, App Sandbox + hardened runtime, ad-hoc signing.

**Spec:** `docs/superpowers/specs/2026-09-21-cross-platform-app-design.md` (stage 2 of three; stage 3 is the retirement/doc task at the end of this plan).

## Global Constraints

- `MACOSX_DEPLOYMENT_TARGET = 26.0`; the iOS floors stay at 26.0.
- Core configuration identical on both platforms: same per-file `COMPILER_FLAGS` from the fork's GENie lib map, same `-D` set (`FORCE_DRC_C_BACKEND=1`, `DATAROVER_IOS_NO_JIT_FLUSH=1`, `NDEBUG`).
- The macOS core must NOT see `$(SRCROOT)/Core/ios_compat` (it shadows the real `<Carbon/Carbon.h>`), and must NOT compile `Core/datarover_carboncore_stubs.cpp` (its `Pasteboard*`/`kUTType*` definitions collide with the real Carbon symbols).
- No edits to the MAME fork, to `Core/file-list.txt`, or to any emulation source.
- macOS app: bundle id `com.example.DataRover.mac`, product name `DataRover.app`, App Sandbox + hardened runtime, ad-hoc signed, state root `~/Library/Containers/com.example.DataRover.mac/Data/Library/Application Support/DataRover/{roms,nvram,cfg,packages,logs}`.
- No migration of `~/Library/Application Support/DataRover/` (decided in the spec): the app boots fresh in its container.
- Package installs use the in-process `datarover_install_package_named` channel; the PTY path stays CLI-only.
- `xcodegen generate && python3 scripts/inject_mame_sources.py` stays the regeneration path and must remain idempotent for both core targets.
- The SDL CLI, its PTY contract, and every headless regression stay untouched and working.
- ROM fixture: `~/Library/Application Support/DataRover/roms/datarover840/magiccap-usa.image`, SHA-256 `94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b`.

---

### Task 1: macOS core target and per-target source injection

**Files:**
- Modify: `apple/DataRover/project.yml` (setting groups, new `DataRoverCoreMac` target)
- Modify: `apple/DataRover/scripts/inject_mame_sources.py` (per-target phases, exclusions, import rename)
- Move: `apple/DataRover/scripts/gen_ios_libmap.py` → `gen_mame_libmap.py`

**Interfaces:**
- Consumes: `apple/DataRover/Core/{file-list.txt,ios_compat/}`, the fork's lib map, stage 1's project layout.
- Produces: a `libDataRoverCoreMac.a` for macOS 26 that Task 2's app target links; an injection script that fills both core targets' Sources phases; `m["owner"|"incs"|"defs"]` API unchanged from the renamed lib-map module.

- [ ] **Step 1: Split the platform-dependent settings out of `mame-base`**

Today `settingGroups.mame-base` carries the whole MAME configuration, including `- $(SRCROOT)/Core/ios_compat` in `HEADER_SEARCH_PATHS` (line 60) and `IPHONEOS_DEPLOYMENT_TARGET`. Restructure so one list serves both platforms:

- Move the shared `HEADER_SEARCH_PATHS` list into project-level `settings.base` (a new top-level `settings: base:` block in the spec), with the `$(SRCROOT)/Core/ios_compat` entry **removed**.
- In `settingGroups.mame-base.base`, keep only the non-header settings; add `HEADER_SEARCH_PATHS: ["$(inherited)"]` remains implied — instead add nothing, and give each platform group the extra entry:
  - `settingGroups.mame-ios.base.HEADER_SEARCH_PATHS: - $(inherited)` `- $(SRCROOT)/Core/ios_compat`
  - `settingGroups.mame-mac.base.OTHER_LDFLAGS: - -lc++` `- -framework` `- Carbon` `- -framework` `- CoreAudio` `- -framework` `- CoreFoundation` `- -framework` `- CoreMIDI`
- `targets.DataRoverCore` keeps `groups: [mame-base, mame-ios]`; the new mac target uses `groups: [mame-base, mame-mac]`.

**Verification that iOS is untouched:** before editing, capture the iOS core's resolved settings; after regenerating, capture them again and diff.

```bash
cd apple/DataRover
xcodebuild -project DataRover.xcodeproj -target DataRoverCore -showBuildSettings 2>/dev/null | sort > /tmp/core-ios-before.txt
# ...make the project.yml edits...
xcodegen generate
xcodebuild -project DataRover.xcodeproj -target DataRoverCore -showBuildSettings 2>/dev/null | sort > /tmp/core-ios-after.txt
diff /tmp/core-ios-before.txt /tmp/core-ios-after.txt
```
Expected: no differences in `HEADER_SEARCH_PATHS`, `GCC_PREPROCESSOR_DEFINITIONS`, `IPHONEOS_DEPLOYMENT_TARGET`, `CLANG_CXX_LANGUAGE_STANDARD`, `GCC_OPTIMIZATION_LEVEL` (build-dir-derived paths such as `TARGET_BUILD_DIR` may differ if DerivedData moved; those are not settings changes).

- [ ] **Step 2: Add the macOS core target**

In `targets:`, mirror `DataRoverCore`:

```yaml
  DataRoverCoreMac:
    type: library.static
    platform: macOS
    deploymentTarget: "26.0"
    settings:
      groups: [mame-base, mame-mac]
      base:
        PRODUCT_NAME: DataRoverCoreMac
        SKIP_INSTALL: YES
        SUPPORTED_PLATFORMS: macosx
        GCC_C_LANGUAGE_STANDARD: gnu17
        CLANG_ENABLE_MODULES: NO
        CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF: NO
        GCC_WARN_UNUSED_FUNCTION: NO
        GCC_WARN_64_TO_32_BIT_CONVERSION: NO
        CLANG_CXX_LIBRARY: libc++
        MACOSX_DEPLOYMENT_TARGET: "26.0"
    sources:
      - path: Core/datarover_osd.cpp
      - path: Core/file-list.txt
        buildPhase: none
      - path: Core/gen_sources.py
        buildPhase: none
```
Do not add the `Core/datarover_carboncore_stubs.cpp` entry as a `sources:` row (it arrives through `file-list.txt` injection, and Step 3 excludes it per target).

- [ ] **Step 3: Teach the injector about both core targets**

In `scripts/inject_mame_sources.py`:
- Rename the import to the renamed lib-map module: `import gen_mame_libmap  # noqa: E402`.
- Replace the single-phase lookup (`idx = next((i for i, mm in enumerate(matches) if "datarover_osd.cpp" in mm.group(1)), None)`) with a loop over every `PBXSourcesBuildPhase` that contains `datarover_osd.cpp`, and for each phase determine its owning target name by scanning the `PBXNativeTarget` blocks for one whose `buildPhases` list contains that phase's object id.
- Keep one source set; per phase, skip sources listed in `IOS_ONLY = {"Core/datarover_carboncore_stubs.cpp"}` when the owning target is not `DataRoverCore`.
- Namespace the generated UUIDs per target so two targets never share a `PBXBuildFile` id: `uuid_for(f"{target}:build:{s}")` and `uuid_for(f"ref:{s}")` for the file reference (file references can be shared, but generating per-target refs is simpler and matches the current one-target shape — keep `uuid_for("ref:" + s)` shared if the same `path` string is used, which it is).
- Report counts per target: `print(f"injected {len(added)} sources into {target}")`.

```bash
cd apple/DataRover && python3 scripts/inject_mame_sources.py
```
Expected: `1159 in file-list, 0 already in pbxproj, 1159 to add` then one injection line per core target; a second run reports `N already in pbxproj, 0 to add`.

- [ ] **Step 4: Rename the lib-map module and update its callers**

```bash
cd apple/DataRover/scripts
git mv gen_ios_libmap.py gen_mame_libmap.py
grep -rn "gen_ios_libmap" .. || echo "no stale references"
```
Update the docstring in `gen_mame_libmap.py` (it says "rebuilds the per-library compile map from the MAME fork's generated GENie makefiles" — drop any iOS-specific wording) and `inject_mame_sources.py`'s docstring line that names the old file.

- [ ] **Step 5: Build the macOS core**

```bash
cd apple/DataRover
xcodegen generate && python3 scripts/inject_mame_sources.py
xcodebuild -project DataRover.xcodeproj -target DataRoverCoreMac -configuration Debug \
  -sdk macosx build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. This is a long build (~1159 translation units); run it in the background and continue when it finishes.

If the link fails with undefined symbols, identify the framework that provides each symbol before adding it — do not guess:

```bash
# example for a missing Pasteboard symbol
nm -gU /System/Library/Frameworks/Carbon.framework/Carbon 2>/dev/null | grep -i pasteboard | head
```
Add `-framework <Name>` to `mame-mac`'s `OTHER_LDFLAGS` for each framework the link proves necessary, and record which symbols forced each addition in the commit message.

- [ ] **Step 6: Commit**

```bash
git add apple/DataRover/project.yml apple/DataRover/DataRover.xcodeproj apple/DataRover/scripts
git commit -m "Add the macOS core target; inject the MAME sources per target"
```

---

### Task 2: The macOS app target

**Files:**
- Modify: `apple/DataRover/project.yml` (new `DataRoverMac` target, scheme)
- Create: `apple/DataRover/Mac/DataRoverMacApp.swift`
- Create: `apple/DataRover/Mac/MetalFramebufferView.swift`
- Create: `apple/DataRover/Mac/PointerPenView.swift`
- Create: `apple/DataRover/Mac/MacHostHooks.swift`
- Create: `apple/DataRover/Mac/SupportPaths+macOS.swift`
- Create: `apple/DataRover/Mac/DataRover.entitlements`

**Interfaces:**
- Consumes: `DataRoverCoreMac` (Task 1), `DataRoverKit`/`DataRoverShell` from stage 1 — `DeviceShellView(session:openMenu:screen:)`, `EmulatorBody(session:framebuffer:overlay:)`, `EmulatorControlsSheet(session:loadPackage:)`, `EmulatorSession(nvramDir:cfgDir:packagesDir:romPath:hooks:)`, `PenRouter.send(_:point:bounds:)`/`lift()`, `FramebufferPresenter.attach/detach/setPaused`, `ROMStore(paths:)`, `SupportPaths(root:)`.
- Produces: a launchable `DataRover.app` for macOS.

- [ ] **Step 1: Declare the app target**

```yaml
  DataRoverMac:
    type: application
    platform: macOS
    deploymentTarget: "26.0"
    settings:
      base:
        PRODUCT_NAME: DataRover
        PRODUCT_BUNDLE_IDENTIFIER: com.example.DataRover.mac
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: Mac/DataRover.entitlements
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "26.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        OTHER_LDFLAGS:
          - -lc++
          - -framework
          - Carbon
          - -framework
          - CoreAudio
          - -framework
          - CoreFoundation
          - -framework
          - CoreMIDI
        SWIFT_VERSION: "5.0"
    sources:
      - path: Mac
      - path: App/AppIcon.icon
    dependencies:
      - target: DataRoverCoreMac
      - package: DataRoverKit
        product: DataRoverShell
    info:
      path: Mac/Info.plist
      properties:
        CFBundleDisplayName: DataRover
        LSApplicationCategoryType: public.app-category.utilities
        NSHighResolutionCapable: true
        LSMinimumSystemVersion: "26.0"
```
The `info:` block makes xcodegen write and maintain `Mac/Info.plist` from the spec; commit the generated file. `App/AppIcon.icon` is shared with the iOS target so the Liquid Glass icon and the `.icns` come from one document.

If the `Mac` source entry picks the generated plist up as a bundle resource (the build reports a duplicated `Info.plist` or stages it into `Contents/Resources`), add an exclusion to that source entry rather than moving the file: `- path: Mac` with `excludes: ["Info.plist"]`.

- [ ] **Step 2: Add the app's support root, entry point, and menus**

`Mac/SupportPaths+macOS.swift`:

```swift
// The sandboxed app keeps its state inside its own container. The old
// unsandboxed bundle used ~/Library/Application Support/DataRover, which a
// sandboxed process cannot see at all — hence a fresh boot here.
import DataRoverKit
import Foundation

func macOSSupportPaths() throws -> SupportPaths {
    let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil, create: true)
    let root = base.appendingPathComponent("DataRover", isDirectory: true)
    let paths = SupportPaths(root: root)
    try paths.createDirectories()
    return paths
}
```

`Mac/DataRoverMacApp.swift` — `@main` plus `Commands`, following the iOS container's composition with a macOS pen overlay and no landscape/status-bar handling:

```swift
import DataRoverKit
import DataRoverShell
import SwiftUI
import UniformTypeIdentifiers

@main
struct DataRoverMacApp: App {
    @StateObject private var romStore: ROMStore
    @State private var importError: String?
    @State private var installPackageRequest = false

    init() {
        let paths = (try? macOSSupportPaths()) ?? SupportPaths(root: FileManager.default.temporaryDirectory)
        _romStore = StateObject(wrappedValue: ROMStore(paths: paths))
    }

    var body: some Scene {
        WindowGroup("DataRover") {
            Group {
                if let romURL = romStore.romURL {
                    EmulatorWindowView(romURL: romURL, paths: romStore.paths,
                                       installPackageRequest: $installPackageRequest)
                } else {
                    VStack(spacing: 16) {
                        Text("DataRover").font(.largeTitle)
                        Text("Import your Magic Cap ROM to begin.")
                        Button("Import ROM…") { importROM() }.buttonStyle(.borderedProminent)
                        if let error = romStore.lastImportError ?? importError {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                    .frame(minWidth: 480, minHeight: 320)
                }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import ROM…") { importROM() }
                Button("Install Package…") { installPackageRequest = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView(paths: romStore.paths) }
    }

    private func importROM() {
        guard let url = chooseFile(type: .magicCapImage) else { return }
        romStore.importROM(url, verifyPin: true)   // the launcher's pinned-image contract
    }
}
```

Add to the app target a `UTType` extension mirroring the iOS one (`.magicCapImage`, `.magicCapPackage`), a `chooseFile(type:)` helper wrapping `NSOpenPanel` (`canChooseDirectories: false`, `allowsMultipleSelection: false`), `EmulatorWindowView` (the macOS analogue of the iOS `EmulatorContainerView`: `DeviceShellView` + `EmulatorBody(session:framebuffer:overlay:)` with `MetalFramebufferView` + `PointerPenView`, a `showControls` state driven by the logo, a `.sheet` hosting `EmulatorControlsSheet`, `Save State`/`Restart`/`Install Package…` menu commands acting on the session, and `.onChange(of: installPackageRequest)` opening the package panel), and `SettingsView` (reveals the support folder with `NSWorkspace.shared.activateFileViewerSelecting([paths.root])` and shows the support path as selectable text).

Physical left/right ⌥ keys drive the two guest Option buttons: use `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` in `EmulatorWindowView.onAppear`, comparing `event.keyCode` (58 = left ⌥, 61 = right ⌥) and calling `session.option(0/1, pressed:)`. Remove the monitor in `onDisappear`.

- [ ] **Step 3: Add the three leaf adapters**

`Mac/MetalFramebufferView.swift` — the macOS twin of the iOS representable:

```swift
import DataRoverShell
import MetalKit
import SwiftUI

struct MetalFramebufferView: NSViewRepresentable {
    @ObservedObject var session: EmulatorSession

    func makeCoordinator() -> FramebufferPresenter { FramebufferPresenter(session: session) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.setPaused(session.isPaused)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: FramebufferPresenter) {
        coordinator.detach()
    }
}
```

`Mac/PointerPenView.swift` — mouse events as pen events, reusing `PenRouter`:

```swift
import DataRoverShell
import SwiftUI

/// Left-button drag is a pen stroke; press = down, drag = move, release = up.
struct PointerPenView: NSViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> PenRouter { PenRouter(session: session) }

    func makeNSView(context: Context) -> PenTrackingView {
        let view = PenTrackingView()
        view.router = context.coordinator
        return view
    }

    func updateNSView(_ view: PenTrackingView, context: Context) {}

    final class PenTrackingView: NSView {
        weak var router: PenRouter?

        override func mouseDown(with event: NSEvent) {
            router?.send(.down, point: convert(event.locationInWindow, from: nil), bounds: bounds)
        }
        override func mouseDragged(with event: NSEvent) {
            router?.send(.move, point: convert(event.locationInWindow, from: nil), bounds: bounds)
        }
        override func mouseUp(with event: NSEvent) { router?.lift() }
    }
}
```

`Mac/MacHostHooks.swift` — macOS is not suspended mid-save, but App Nap will throttle it:

```swift
import DataRoverShell
import Foundation

final class MacHostHooks: HostHooks {
    func beginSaveAssertion() -> SaveAssertion {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Saving DataRover state")
        return SaveAssertion(activity)
    }

    func endSaveAssertion(_ assertion: SaveAssertion) {
        guard let activity = assertion.payload as? NSObjectProtocol else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}
```

- [ ] **Step 4: Add the entitlements**

`Mac/DataRover.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
```
No JIT entitlement: the core runs the C DRC backend.

- [ ] **Step 5: Generate and build**

```bash
cd apple/DataRover
xcodegen generate && python3 scripts/inject_mame_sources.py
xcodebuild -project DataRover.xcodeproj -scheme DataRoverMac -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add apple/DataRover/project.yml apple/DataRover/DataRover.xcodeproj apple/DataRover/Mac
git commit -m "Add the sandboxed macOS app target with menu commands and pointer pen"
```

---

### Task 3: Prove the macOS app at parity

**Files:**
- Modify: `apple/DataRover/Mac/*` and `apple/DataRover/project.yml` only as the run reveals defects.

- [ ] **Step 1: Install the ROM into the container and launch**

The app is sandboxed, so the fixture goes into its container directly (equivalent to picking it in the panel):

```bash
APP="$HOME/Library/Containers/com.example.DataRover.mac/Data/Library/Application Support/DataRover"
mkdir -p "$APP/roms/datarover840"
cp ~/Library/Application\ Support/DataRover/roms/datarover840/magiccap-usa.image "$APP/roms/datarover840/"
BUILT=$(xcodebuild -project apple/DataRover/DataRover.xcodeproj -scheme DataRoverMac -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/DataRover.app
open "$BUILT"
sleep 30 && screencapture -x /tmp/mac-stage2-boot.png
```
Expected: `/tmp/mac-stage2-boot.png` shows the device shell with the guest screen (calibration crosshair on a first run, then workbench). Read the screenshot and confirm; if the guest screen is black or the window is empty, that is a defect to fix before proceeding.

- [ ] **Step 2: Verify the flows**

With the app running:
1. Mouse-drag on the guest screen → the three-point calibration completes (screenshot before/after).
2. Left/right ⌥ → the guest Option buttons engage (the rails darken and the guest reacts).
3. File ▸ Save State → the "State saved" message appears; File ▸ Restart → the guest reboots to the workbench.
4. File ▸ Install Package… → pick a `.pkg`; the banner asks for the Storeroom computer; opening it in the guest completes the install.
5. Quit and relaunch → the workbench returns from the checkpoint.

Capture a screenshot for step 2 and one for step 4.

- [ ] **Step 3: Verify the sandbox and the entitlements**

```bash
codesign -d --entitlements - "$BUILT" 2>&1 | grep -A1 -E "app-sandbox|user-selected|network.client"
codesign -dv --verbose=2 "$BUILT" 2>&1 | grep -E "flags|Identifier"
ls "$HOME/Library/Containers/com.example.DataRover.mac/Data/Library/Application Support/DataRover"
```
Expected: all three entitlements present; `flags=...runtime...`; the container holds `roms/`, `nvram/`, `cfg/`, `packages/`. The unsandboxed path `~/Library/Application Support/DataRover/` must be untouched by the app.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A apple/DataRover/Mac apple/DataRover/project.yml
git commit -m "macOS app: fixes found at first parity run"
```
If no fixes were needed, skip this commit and say so in the report.

---

### Task 4: Retire the SDL launcher bundle and update the docs

**Files:**
- Delete: `packaging/macos/{launcher.sh,Info.plist,DataRover.icns}`, `tools/build_mac_app.sh`
- Create: `tools/build_mac_swift_app.sh`
- Move: `docs/ios-shell.md` → `docs/apple-shell.md`
- Modify: `PLAN.md`, `docs/mame-bringup.md:363`, `README.md` if it names the launcher

**Interfaces:**
- Consumes: the working `DataRoverMac` scheme from Task 3.
- Produces: a documented, scripted way to build the macOS app; no remaining references to the retired bundle.

- [ ] **Step 1: Confirm nothing live depends on the retired bundle**

```bash
grep -rn "build_mac_app\|packaging/macos" --include="*.py" --include="*.sh" --include="*.md" --include="*.yml" . | grep -v "^./.git/"
```
Expected: only `docs/superpowers/**` historical plans/specs (leave those), plus the files being deleted here. `tools/pclink_send.py` and the regressions drive the SDL CLI binary directly and must NOT be touched — verify each hit by reading it before deleting anything.

- [ ] **Step 2: Replace the staging script**

`tools/build_mac_swift_app.sh`:

```bash
#!/usr/bin/env bash
# Build the native macOS app and stage it at build/DataRover.app (the path the
# retired SDL launcher bundle used to occupy).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/apple/DataRover/DataRover.xcodeproj"
CONFIG="${CONFIG:-Debug}"

xcodebuild -project "$PROJECT" -scheme DataRoverMac -configuration "$CONFIG" \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" build

PRODUCT="$(xcodebuild -project "$PROJECT" -scheme DataRoverMac -configuration "$CONFIG" \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/DataRover.app"
rm -rf "$REPO_ROOT/build/DataRover.app"
cp -R "$PRODUCT" "$REPO_ROOT/build/DataRover.app"
codesign --force -s - "$REPO_ROOT/build/DataRover.app"
printf 'staged %s\n' "$REPO_ROOT/build/DataRover.app"
```

```bash
chmod +x tools/build_mac_swift_app.sh
git rm packaging/macos/launcher.sh packaging/macos/Info.plist packaging/macos/DataRover.icns tools/build_mac_app.sh
```
Then run it once and confirm the staged bundle launches and boots the guest:

```bash
tools/build_mac_swift_app.sh && open build/DataRover.app
```

- [ ] **Step 3: Rename and extend the shell document**

```bash
git mv docs/ios-shell.md docs/apple-shell.md
```
Keep the existing iOS content, retitle the document for both apps, and add a macOS section: build (`tools/build_mac_swift_app.sh` or the Xcode scheme), the sandboxed container state root and the deliberate absence of migration from the old unsandboxed path, menu commands and the ⌥-key Option mapping, and the fact that package installs use the in-process channel on both platforms.

- [ ] **Step 4: Update the pointers**

- `PLAN.md`: state that the Apple apps share `apple/DataRoverKit` and that both iOS and macOS shells are built from `apple/DataRover`.
- `docs/mame-bringup.md:363`: `tools/start_manual.sh` remains the CLI launcher for headless work; the native macOS app is now the default interactive path.

- [ ] **Step 5: Commit and push**

```bash
git add -A
git commit -m "Retire the SDL launcher bundle; document the native macOS app"
git push origin main
```

---

## Verification summary (stage 2)

| Check | Command | Expected |
|---|---|---|
| iOS settings unchanged by the group split | `xcodebuild -showBuildSettings -target DataRoverCore` diff | no settings differences |
| Injection idempotence | run `inject_mame_sources.py` twice | second run adds 0 |
| macOS core | `xcodebuild -target DataRoverCoreMac -sdk macosx build` | build succeeded |
| macOS app | build, install ROM into the container, launch | guest boots to calibration → workbench |
| Sandbox | `codesign -d --entitlements -` + container listing | 3 entitlements, state in the container |
| SDL tooling intact | `python3 tools/pclink_regression.py --help` and the CLI binary still present | unaffected |