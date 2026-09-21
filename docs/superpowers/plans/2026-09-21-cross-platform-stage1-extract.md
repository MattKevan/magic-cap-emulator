# Cross-platform DataRover — Stage 1: extract the shared layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the iOS app's portable logic and shared UI into a local SwiftPM package (`apple/DataRoverKit`) consumed by a now-thin iOS app target, with no user-visible behavior change.

**Architecture:** Three modules in one local package. `CDataRoverABI` (C) carries the hand-written redeclaration of the core's 17-function ABI. `DataRoverKit` holds pure, platform-neutral logic (guest geometry, support paths, ROM store, package staging, save-status decoding) and depends on nothing. `DataRoverShell` holds the ABI wrappers, `EmulatorSession`, `HostHooks`, the Metal framebuffer presenter and the shared SwiftUI device shell. The iOS app target keeps only its `@main` entry, the two `UIViewRepresentable` leaf adapters, its `HostHooks` implementation, and its Info.plist/icon. Nothing in `ios/DataRover/Core/`, the MAME fork, or the emulation core changes.

**Tech Stack:** SwiftPM (tools 5.9+, `.iOS("26.0")`/`.macOS("26.0")`), SwiftUI, MetalKit, xcodegen 2.45.4 for the Xcode project, `swift test` for the pure module.

**Spec:** `docs/superpowers/specs/2026-09-21-cross-platform-app-design.md` (stage 1 of three). Stage 2 (the macOS target) and stage 3 (retire the SDL launcher bundle) are separate plans.

## Global Constraints

- Deployment floors: `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, and every package platform is `.iOS("26.0")` / `.macOS("26.0")`.
- The emulation core is untouched: no edits under `apple/DataRover/Core/`, no changes to `Core/file-list.txt`, no flag changes, no MAME fork edits.
- The iOS app's user-visible behavior must not change: ROM import → calibration → workbench, Option rails, menu sheet with Save/Restart/Load Package, install banner, Metal blit with aspect-fit letterbox and 2bpp expansion, pause when backgrounded or the sheet is open.
- No conditional compilation (`#if`) inside the package: platform leaf adapters live in the app target.
- `DataRoverKit` imports Foundation/CoreGraphics only — never UIKit, AppKit, SwiftUI, MetalKit, or `CDataRoverABI`.
- Package code that loads device-shell artwork uses `Image(…, bundle: .module)`.
- The committed `project.pbxproj` is the build input; regenerate with `xcodegen generate` and then `python3 scripts/inject_mame_sources.py`. Both must stay idempotent.
- `swift test` must pass without linking the core static library.
- The ROM fixture for manual verification is `~/Library/Application Support/DataRover/roms/datarover840/magiccap-usa.image`, SHA-256 `94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b`. Copy it — never move or edit it.

---

### Task 1: Rename `ios/` to `apple/` and set the 26.0 floor

**Files:**
- Move: `ios/DataRover/` → `apple/DataRover/` (`git mv`, whole tree)
- Modify: `apple/DataRover/Core/gen_sources.py:4` (docstring path)
- Modify: `apple/DataRover/project.yml:4,13,148,174,187` (deployment targets)

**Interfaces:**
- Consumes: nothing.
- Produces: the final repo paths every later task uses — `apple/DataRover/{project.yml,DataRover.xcodeproj,App/,Core/,scripts/}` — and the 26.0 floors in the generated project.

- [ ] **Step 1: Move the tree**

```bash
cd /Users/mattkevan/Dev/magic-cap-emulator
git mv ios apple
```

- [ ] **Step 2: Update the one live path reference**

In `apple/DataRover/Core/gen_sources.py`, change the docstring's `ios/DataRover/Core/file-list.txt` to `apple/DataRover/Core/file-list.txt`. Leave `docs/superpowers/**` alone — those are historical records.

```bash
grep -rn "ios/DataRover" --include="*.py" --include="*.yml" --include="*.sh" apple/ || echo "no live references"
```
Expected: `no live references`

- [ ] **Step 3: Bump both deployment targets to 26.0**

In `apple/DataRover/project.yml`:
- `options.deploymentTarget.iOS: "16.0"` → `"26.0"`
- `settingGroups.mame-base.base.IPHONEOS_DEPLOYMENT_TARGET: "16.0"` → `"26.0"`
- `targets.DataRoverCore.deploymentTarget: "16.0"` → `"26.0"`
- `targets.DataRover.deploymentTarget: "16.0"` → `"26.0"`
- `targets.DataRover.settings.base.IPHONEOS_DEPLOYMENT_TARGET: "16.0"` → `"26.0"`

- [ ] **Step 4: Regenerate and confirm the project still matches**

```bash
cd apple/DataRover
xcodegen generate && python3 scripts/inject_mame_sources.py
cp DataRover.xcodeproj/project.pbxproj /tmp/stage1-task1.pbxproj
xcodegen generate && python3 scripts/inject_mame_sources.py
diff -q /tmp/stage1-task1.pbxproj DataRover.xcodeproj/project.pbxproj && echo "injection is idempotent"
grep -n "IPHONEOS_DEPLOYMENT_TARGET" DataRover.xcodeproj/project.pbxproj | head
grep -c 'MAME_DIR' DataRover.xcodeproj/project.pbxproj
```
Expected: `injection is idempotent`; every `IPHONEOS_DEPLOYMENT_TARGET` reads `26.0`; the `MAME_DIR` count is unchanged from before the rename (compare with `git stash list`-free check: it must equal the count in the previous commit, obtainable with `git show HEAD:ios/DataRover/DataRover.xcodeproj/project.pbxproj | grep -c MAME_DIR`).

- [ ] **Step 5: Build and run the iOS app to prove the rename and floor are behavior-neutral**

```bash
cd apple/DataRover
DEV=0806B7B8-62A5-4F4A-A7D6-B4D1D2F62423            # iPhone 17 Pro, iOS 27
xcrun simctl boot $DEV 2>/dev/null; xcrun simctl bootstatus $DEV -b
xcodebuild -project DataRover.xcodeproj -scheme DataRover -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

Then place the ROM fixture in the app container and confirm the workbench:

```bash
xcrun simctl install $DEV ~/Library/Developer/Xcode/DerivedData/DataRover-*/Build/Products/Debug-iphonesimulator/DataRover.app
APP=$(xcrun simctl get_app_container $DEV com.example.DataRover data)
mkdir -p "$APP/Documents/roms/datarover840"
cp ~/Library/Application\ Support/DataRover/roms/datarover840/magiccap-usa.image \
   "$APP/Documents/roms/datarover840/magiccap-usa.image"
xcrun simctl launch $DEV com.example.DataRover
sleep 20 && xcrun simctl io $DEV screenshot /tmp/stage1-task1.png
```
Expected: the screenshot shows the DataRover device shell with the Magic Cap calibration screen or workbench (not the "Import your Magic Cap ROM" empty state, not a white screen).

- [ ] **Step 6: Commit**

```bash
cd /Users/mattkevan/Dev/magic-cap-emulator
git add -A
git commit -m "apple: rename ios/ to apple/, raise deployment floors to 26.0"
```

---

### Task 2: Package skeleton, the C ABI module, and the ABI drift checker

**Files:**
- Create: `apple/DataRoverKit/Package.swift`
- Create: `apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h` (copy of `apple/DataRover/App/CoreBridge.h`, unchanged content)
- Create: `apple/DataRoverKit/Sources/CDataRoverABI/shim.c`
- Create: `apple/DataRoverKit/Sources/DataRoverKit/GuestGeometry.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverKitTests/GuestGeometryTests.swift`
- Create: `tools/check_core_abi.py`

**Interfaces:**
- Consumes: nothing (the app keeps its own `App/CoreBridge.h` until Task 4).
- Produces: `import CDataRoverABI` exposing the 17 ABI declarations; `DataRoverKit.GuestGeometry` with `width = 480`, `height = 320`, `screenRect(in: CGRect) -> CGRect`, `guestCoords(point: CGPoint, in: CGRect) -> (x: Int, y: Int)?`.

- [ ] **Step 1: Write the failing geometry test**

`apple/DataRoverKit/Tests/DataRoverKitTests/GuestGeometryTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import DataRoverKit

@Suite struct GuestGeometryTests {
    /// Exact-fit bounds: the guest grid maps 1:1.
    @Test func exactFitMapsCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 320)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 0, y: 0), in: bounds)! == (0, 0))
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 479, y: 319), in: bounds)! == (479, 319))
    }

    /// Letterboxed bounds: the guest rect is centered, so the pen must be
    /// offset by the bar height before scaling.
    @Test func letterboxOffsetsTheMapping() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720) // 2x fit, 40pt bars
        let center = GuestGeometry.guestCoords(point: CGPoint(x: 480, y: 360), in: bounds)!
        #expect(center == (239, 159))
        let topLeftOfScreen = GuestGeometry.guestCoords(point: CGPoint(x: 0, y: 40), in: bounds)!
        #expect(topLeftOfScreen == (0, 0))
    }

    /// Points in the letterbox bars are outside the guest screen.
    @Test func pointsOutsideTheScreenAreRejected() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 480, y: 20), in: bounds) == nil)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 480, y: 700), in: bounds) == nil)
    }

    /// The right and bottom edges still clamp into range rather than rejecting.
    @Test func edgesClamp() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
        #expect(GuestGeometry.guestCoords(point: CGPoint(x: 960, y: 680), in: bounds)! == (479, 319))
    }

    /// Degenerate bounds never produce coordinates.
    @Test func zeroBoundsAreRejected() {
        #expect(GuestGeometry.guestCoords(point: .zero, in: .zero) == nil)
    }

    @Test func screenRectIsCenteredAndAspectFit() {
        let rect = GuestGeometry.screenRect(in: CGRect(x: 0, y: 0, width: 960, height: 720))
        #expect(rect == CGRect(x: 0, y: 40, width: 960, height: 640))
    }
}
```

- [ ] **Step 2: Write `Package.swift`, then run the test to watch it fail**

`apple/DataRoverKit/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DataRoverKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "DataRoverKit", targets: ["DataRoverKit"]),
        .library(name: "DataRoverShell", targets: ["DataRoverShell"]),
    ],
    targets: [
        .target(name: "CDataRoverABI"),
        .target(name: "DataRoverKit"),
        .testTarget(name: "DataRoverKitTests", dependencies: ["DataRoverKit"]),
    ]
)
```

The `DataRoverShell` target and the `DataRoverShell` product are added in Task 3, when its sources and resources exist — SwiftPM rejects a target with no sources and a `.process("Resources")` path that does not exist, so they cannot be declared here.

```bash
cd apple/DataRoverKit && swift test 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'GuestGeometry' in scope`.

- [ ] **Step 3: Implement `GuestGeometry`**

`apple/DataRoverKit/Sources/DataRoverKit/GuestGeometry.swift`:

```swift
// Guest screen geometry: the 480x320 guest buffer is shown aspect-fit
// (letterboxed) inside the hosting view, so host points must have the
// letterbox offset removed before they become pen coordinates.
import CoreGraphics

public enum GuestGeometry {
    public static let width = 480
    public static let height = 320

    /// The aspect-fit rect the guest screen occupies inside `bounds`.
    public static func screenRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let fit = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        let size = CGSize(width: CGFloat(width) * fit, height: CGFloat(height) * fit)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Guest-space coordinate for a host point, or nil outside the guest
    /// screen (letterbox bars). Clamps inclusive at the right/bottom edge,
    /// matching the driver's defensive clamp.
    public static func guestCoords(point: CGPoint, in bounds: CGRect) -> (x: Int, y: Int)? {
        let rect = screenRect(in: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let gx = (point.x - rect.minX) / rect.width * CGFloat(width - 1)
        let gy = (point.y - rect.minY) / rect.height * CGFloat(height - 1)
        guard gx >= 0, gy >= 0, gx <= CGFloat(width - 1), gy <= CGFloat(height - 1) else { return nil }
        return (min(width - 1, max(0, Int(gx))), min(height - 1, max(0, Int(gy))))
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd apple/DataRoverKit && swift test 2>&1 | tail -12
```
Expected: `Executed 6 tests, with 0 failures` (Swift Testing prints per-suite results; all pass).

- [ ] **Step 5: Add the C ABI target**

```bash
mkdir -p apple/DataRoverKit/Sources/CDataRoverABI/include
cp apple/DataRover/App/CoreBridge.h apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h
cat > apple/DataRoverKit/Sources/CDataRoverABI/shim.c <<'EOF'
// The ABI lives in the app's linked static library, not in this package.
// This translation unit exists so SwiftPM produces an importable module
// from include/CoreBridge.h; it deliberately defines nothing.
#include "CoreBridge.h"
EOF
```
Note: this is a copy, not a move — the app keeps its own header (and its `SWIFT_OBJC_BRIDGING_HEADER` setting) until Task 4 deletes both, so every commit in this plan leaves the app buildable.

Then edit the package copy's header comment: it no longer serves as a bridging header, so replace the `NOTE: no #pragma once — this file is the bridging header (a main file)` sentence with `NOTE: no #pragma once — the module is imported, and the include guard above suffices.` Leave every declaration untouched (`tools/check_core_abi.py` enforces that).

```bash
cd apple/DataRoverKit && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 6: Write the ABI drift checker**

`tools/check_core_abi.py`:

```python
#!/usr/bin/env python3
"""Check the package's ABI redeclaration against the fork's real header.

The Swift layer never includes the fork header (it has no MAME header search
paths), so CoreBridge.h is a hand copy and can drift. The copy is a
deliberate subset of the fork's declarations, so this checks one direction:
every function declared in CoreBridge.h must exist in the fork header with
the same parameter and return types. Fork-only functions (for example
datarover_emulated_seconds) are ignored.

Usage: python3 tools/check_core_abi.py [--mame-dir DIR]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
COPY = os.path.join(ROOT, "apple", "DataRoverKit", "Sources", "CDataRoverABI",
                    "include", "CoreBridge.h")
DEFAULT_MAME = os.path.normpath(os.path.join(ROOT, "..", "mame"))

DECL = re.compile(r"^\s*(?:const\s+)?[\w\s\*]+?\b(datarover_\w+)\s*\(([^;]*)\)\s*;", re.M)


def normalise(text):
    """Collapse whitespace so formatting differences do not matter."""
    return re.sub(r"\s+", " ", text).strip()


def declarations(path):
    """Map function name -> (prefix, params) for every declaration in a header."""
    with open(path) as f:
        body = f.read()
    found = {}
    for match in DECL.finditer(body):
        prefix = normalise(body[match.start():match.start(1)])
        params = normalise(match.group(2))
        found[match.group(1)] = (prefix, params)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mame-dir", default=os.environ.get("MAME_DIR", DEFAULT_MAME))
    ap.add_argument("--fork-header", default=None,
                    help="path to the fork's datarover_core.h (default: <mame-dir>/src/libdatarover/datarover_core.h)")
    args = ap.parse_args()
    fork = args.fork_header or os.path.join(args.mame_dir, "src", "libdatarover", "datarover_core.h")
    if not os.path.exists(fork):
        print(f"fork header not found: {fork}", file=sys.stderr)
        return 2
    have = declarations(COPY)
    want = declarations(fork)
    problems = []
    for name, (prefix, params) in sorted(have.items()):
        if name not in want:
            problems.append(f"{name}: declared in CoreBridge.h but absent from the fork header")
            continue
        fprefix, fparams = want[name]
        if params != fparams:
            problems.append(f"{name}: parameter mismatch\n    copy: {params}\n    fork: {fparams}")
        if prefix != fprefix:
            problems.append(f"{name}: return type mismatch\n    copy: {prefix}\n    fork: {fprefix}")
    print(f"{len(have)} declarations checked against {fork}")
    for problem in problems:
        print(f"MISMATCH {problem}")
    if problems:
        return 1
    print("ABI copy matches the fork header")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 7: Run the checker**

```bash
cd /Users/mattkevan/Dev/magic-cap-emulator && python3 tools/check_core_abi.py
```
Expected: `<N> declarations checked against /Users/mattkevan/Dev/mame/src/libdatarover/datarover_core.h` then `ABI copy matches the fork header`, exit 0. If it reports mismatches, fix `CoreBridge.h` to match the fork — the fork header is authoritative.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add DataRoverKit package skeleton with the C ABI module and guest geometry"
```

---

### Task 3: Move the pure logic and the shared shell into the package

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverKit/SupportPaths.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverKit/ROMStore.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverKit/PackageStaging.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverKit/ROMPin.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverKit/SaveState.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverKitTests/{SupportPathsTests,ROMStoreTests,PackageStagingTests,ROMPinTests,SaveStateTests}.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverShell/{CoreHandle,EmulatorSession,HostHooks,PenRouter,FramebufferPresenter,DeviceShellView,EmulatorControlsSheet,InstallStatusBanner,EmulatorBody}.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverShell/Resources/Assets.xcassets` (copy of `apple/DataRover/App/Assets.xcassets`)

**Interfaces:**
- Consumes: `DataRoverKit.GuestGeometry`, `CDataRoverABI` declarations, the iOS sources listed below.
- Produces (used by Task 4's thin iOS app):
  - `SupportPaths(root: URL)` with `.root/.roms/.nvram/.cfg/.packages/.logs/.canonicalROM/.createDirectories() throws`
  - `@MainActor final class ROMStore: ObservableObject` with `init(paths: SupportPaths)`, `romURL: URL?`, `lastImportError: String?`, `importROM(_ url: URL)`, `importROM(_ url: URL, verifyPin: Bool)`
  - `PackageStaging.store(_ url: URL, into packagesDir: URL) throws -> URL`
  - `ROMPin.verify(_ url: URL) -> Bool`, `ROMPin.sha256`
  - `SaveState` (`idle/pending/saved/failed`) and `SaveState.decode(_ raw: Int32) -> SaveState`
  - `EmulatorSession(nvramDir:cfgDir:packagesDir:romPath:hooks:)`, `EmulatorSession.hooks`; an overload without `hooks:` defaults to `NoOpHostHooks()`
  - `protocol HostHooks` (`beginSaveAssertion() -> SaveAssertion`, `endSaveAssertion(_:)`), `final class SaveAssertion`, `final class NoOpHostHooks`
  - `PenRouter(session:)` + `send(_ phase: PenPhase, point: CGPoint, bounds: CGRect)`
  - `FramebufferPresenter(session:)` + `attach(view: MTKView)`, `detach()`, `setPaused(_:)`
  - `DeviceShellView(session:openMenu:screen:)`, `EmulatorControlsSheet(session:loadPackage:)`, `InstallStatusBanner(session:)`, `EmulatorBody(session:framebuffer:overlay:)`

- [ ] **Step 1: Write failing tests for the pure units**

`Sources`/tests are new files, so write the tests first. Include, verbatim:

```swift
// Tests/DataRoverKitTests/SupportPathsTests.swift
import Foundation
import Testing
@testable import DataRoverKit

@Suite struct SupportPathsTests {
    @Test func layoutMatchesTheContainerContract() {
        let paths = SupportPaths(root: URL(fileURLWithPath: "/tmp/root"))
        #expect(paths.nvram.path == "/tmp/root/nvram")
        #expect(paths.cfg.path == "/tmp/root/cfg")
        #expect(paths.packages.path == "/tmp/root/packages")
        #expect(paths.canonicalROM.path == "/tmp/root/roms/datarover840/magiccap-usa.image")
    }

    @Test func createDirectoriesIsIdempotent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let paths = SupportPaths(root: root)
        try paths.createDirectories()
        try paths.createDirectories()
        #expect(FileManager.default.fileExists(atPath: paths.nvram.path))
        #expect(FileManager.default.fileExists(atPath: paths.packages.path))
        try? FileManager.default.removeItem(at: root)
    }
}
```

```swift
// Tests/DataRoverKitTests/ROMPinTests.swift
import Foundation
import Testing
@testable import DataRoverKit

@Suite struct ROMPinTests {
    @Test func rejectsAMissingFile() {
        #expect(ROMPin.verify(URL(fileURLWithPath: "/nonexistent.image")) == false)
    }

    @Test func acceptsThePinnedImageWhenPresent() throws {
        let pinned = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DataRover/roms/datarover840/magiccap-usa.image")
        guard FileManager.default.fileExists(atPath: pinned.path) else {
            Issue.record("ROM fixture missing; skipped")
            return
        }
        #expect(ROMPin.verify(pinned))
    }

    @Test func rejectsAWrongFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("not a rom".utf8).write(to: url)
        #expect(ROMPin.verify(url) == false)
        try? FileManager.default.removeItem(at: url)
    }
}
```

```swift
// Tests/DataRoverKitTests/SaveStateTests.swift
import Testing
@testable import DataRoverKit

@Suite struct SaveStateTests {
    @Test func decodesTheABIContract() {
        #expect(SaveState.decode(0) == .idle)
        #expect(SaveState.decode(1) == .pending)
        #expect(SaveState.decode(2) == .saved)
        #expect(SaveState.decode(-1) == .failed)
        #expect(SaveState.decode(99) == .failed)
    }
}
```

```swift
// Tests/DataRoverKitTests/PackageStagingTests.swift
import Foundation
import Testing
@testable import DataRoverKit

@Suite struct PackageStagingTests {
    @Test func copiesAndKeepsBothOnNameCollision() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("DvorakKeyboard.pkg")
        try Data("first".utf8).write(to: src)
        let dest = dir.appendingPathComponent("packages", isDirectory: true)

        let first = try PackageStaging.store(src, into: dest)
        let second = try PackageStaging.store(src, into: dest)

        #expect(first.lastPathComponent == "DvorakKeyboard.pkg")
        #expect(second.lastPathComponent.hasSuffix("DvorakKeyboard.pkg"))
        #expect(second.lastPathComponent != first.lastPathComponent)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("first".utf8))
        try? FileManager.default.removeItem(at: dir)
    }
}
```

```swift
// Tests/DataRoverKitTests/ROMStoreTests.swift
import Foundation
import Testing
@testable import DataRoverKit

@MainActor
@Suite struct ROMStoreTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func prefersTheExactImageLayout() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: paths.canonicalROM.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("exact".utf8).write(to: paths.canonicalROM)
        try Data("other".utf8).write(to: paths.roms.appendingPathComponent("other.image"))
        #expect(ROMStore(paths: paths).romURL?.lastPathComponent == "magiccap-usa.image")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func fallsBackToAnyImage() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        try paths.createDirectories()
        try Data("other".utf8).write(to: paths.roms.appendingPathComponent("other.image"))
        #expect(ROMStore(paths: paths).romURL?.lastPathComponent == "other.image")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func importsIntoTheCanonicalPath() throws {
        let root = try makeRoot()
        let paths = SupportPaths(root: root)
        let store = ROMStore(paths: paths)
        let src = root.appendingPathComponent("picked.image")
        try Data("picked".utf8).write(to: src)
        store.importROM(src)
        #expect(store.romURL?.path == paths.canonicalROM.path)
        #expect(try Data(contentsOf: paths.canonicalROM) == Data("picked".utf8))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func reportsAMissingSource() throws {
        let root = try makeRoot()
        let store = ROMStore(paths: SupportPaths(root: root))
        store.importROM(root.appendingPathComponent("absent.image"))
        #expect(store.romURL == nil)
        #expect(store.lastImportError != nil)
        try? FileManager.default.removeItem(at: root)
    }
}
```

Run them and watch them fail:

```bash
cd apple/DataRoverKit && swift test 2>&1 | tail -15
```
Expected: FAIL — `cannot find 'SupportPaths'/'ROMStore'/'PackageStaging'/'ROMPin'/'SaveState' in scope`.

- [ ] **Step 2: Implement the pure units**

Write these five files. Behavior is the current app's, moved:

`SupportPaths.swift` — `public struct SupportPaths: Sendable` with `root` and the derived URLs listed in Interfaces, `canonicalROM` = `roms/datarover840/magiccap-usa.image`, and `createDirectories()` creating `roms`, `nvram`, `cfg`, `packages` with `withIntermediateDirectories: true`.

`ROMStore.swift` — moved from `apple/DataRover/App/DataRoverApp.swift:22-57` with these changes: the root comes from `paths` instead of `Documents`; `restore` keeps the exact-layout-then-any-image preference verbatim; `importROM(_ url: URL)` copies to `paths.canonicalROM` (creating `roms/datarover840/`), keeping the security-scoped start/stop and the "Could not access the picked file." message; add `importROM(_ url: URL, verifyPin: Bool)` where `verifyPin == true` rejects a file failing `ROMPin.verify` with the message `That file is not the pinned MagicCap-USA.image.` and `importROM(_:)` calls it with `verifyPin: false`.

`PackageStaging.swift` — `public enum PackageStaging` with `store(_ url: URL, into packagesDir: URL) throws -> URL`, moved from `apple/DataRover/App/DataRoverApp.swift:180-193` (security-scoped copy, `UUID()`-prefixed name on collision).

`ROMPin.swift` — `public enum ROMPin` with `public static let sha256 = "94785cb334f14eac00ed200af014c35972b4f25694103bc6a49b3afa280a6f1b"` and `public static func verify(_ url: URL) -> Bool` using CryptoKit `SHA256` over a streaming read (`FileHandle.read(upToCount:)` in a loop, 1 MiB chunks); any read failure returns false.

`SaveState.swift` — `public enum SaveState: Equatable { case idle, pending, saved, failed }` and `public static func decode(_ raw: Int32) -> SaveState` mapping `0 → .idle`, `1 → .pending`, `2 → .saved`, anything else → `.failed`.

- [ ] **Step 3: Run the pure tests**

```bash
cd apple/DataRoverKit && swift test 2>&1 | tail -12
```
Expected: all suites pass (the pinned-ROM test skips with `Issue.record` only if the fixture is absent).

- [ ] **Step 4: Move the shell sources into `DataRoverShell`**

Move (adapt, do not rewrite) from the iOS app:

- `CoreBridge.swift:11-58` → `CoreHandle.swift`: the `PenPhase` enum, `coreCreate`, `coreDestroy`, `coreFramebuffer`, `corePen`, `coreInstallPackage`, `coreInstallProgress`, made `public`. Add `import CDataRoverABI`.
- `CoreBridge.swift:63-197` → `EmulatorSession.swift`: the class verbatim except `import UIKit` is dropped, the initializer gains `packagesDir: String` (stored), and:
  - `installPackage(_ url: URL)` calls `PackageStaging.store(url, into: URL(fileURLWithPath: packagesDir))` in place of the app's `PackageImport.store(url)`, then `Data(contentsOf:)` as today.
  - `beginSaveAssertion` is added (see below), and the two `UIApplication` call sites become hook calls:
  - `setForeground(false)`: `let assertion = hooks.beginSaveAssertion(); pollSave(assertion: assertion)` instead of `UIApplication.shared.beginBackgroundTask`.
  - `pollSave(backgroundTask:)` becomes `pollSave(assertion: SaveAssertion?)`, and its `defer` calls `hooks.endSaveAssertion(assertion)` when non-nil.
- `ToolbarView.swift` (whole file) → `DeviceShellView.swift` and `EmulatorControlsSheet.swift`, with `DeviceShellView`, `EmulatorControlsSheet` and `InstallStatusBanner` made `public` (and their `init`s `public`). `OptionControl` stays internal.
- `TouchPenView.swift:31-50` (`Coordinator.guestCoords`) is superseded by `DataRoverKit.GuestGeometry`; the new `PenRouter.swift` is:

```swift
import CoreGraphics
import DataRoverKit

/// Forwards host pointer events to the core as guest pen events, removing
/// the aspect-fit letterbox offset first. One instance per host view.
public final class PenRouter {
    private let session: EmulatorSession

    public init(session: EmulatorSession) { self.session = session }

    public func send(_ phase: PenPhase, point: CGPoint, bounds: CGRect) {
        guard let handle = session.handle,
              let (x, y) = GuestGeometry.guestCoords(point: point, in: bounds) else { return }
        corePen(handle, phase: phase, x: x, y: y)
    }

    /// Pen-up carries no coordinates in the ABI: lifting always releases.
    public func lift() {
        guard let handle = session.handle else { return }
        corePen(handle, phase: .up, x: 0, y: 0)
    }
}
```

- `EmulatorView.swift:52-216` (the `Coordinator`) → `FramebufferPresenter.swift`: a `public final class FramebufferPresenter: NSObject, MTKViewDelegate` with the same persistent `texture`, `pipeline`, `sampler`, `queue`, `staging`, `levels`, `shaderSource`, `expand2bpp` and the aspect-fit draw, plus:
  - `attach(view: MTKView)`: sets `view.device`, `view.colorPixelFormat = .bgra8Unorm`, `view.framebufferOnly = true`, `view.enableSetNeedsDisplay = false`, `view.preferredFramesPerSecond = 30`, `view.isPaused = false`, `view.delegate = self`, then builds the resources.
  - `setPaused(_ paused: Bool) { view?.isPaused = paused }`
  - No `CADisplayLink`: `MTKView` drives `draw(in:)` at `preferredFramesPerSecond` on both platforms, and the existing frame-revision guard already makes a no-change draw a no-op. (Ruling: replaces the iOS-only `CADisplayLink` pacing with the cross-platform `MTKView` pacing; if wrong, the screen stops refreshing, which the Task 4 run check catches immediately.)
- `Imports`: `DataRoverShell` starts each file with `import SwiftUI` / `import MetalKit` / `import DataRoverKit` as needed; never `import UIKit` or `import AppKit`.
- `EmulatorBody.swift`: the screen composition lifted from `DataRoverApp.swift:126-151`, generic over both leaf views:

```swift
import DataRoverKit
import SwiftUI

/// Guest screen + install banner + boot state, parameterized by the
/// platform's framebuffer and pen-overlay views.
public struct EmulatorBody<Framebuffer: View, Overlay: View>: View {
    @ObservedObject private var session: EmulatorSession
    private let framebuffer: () -> Framebuffer
    private let overlay: () -> Overlay

    public init(session: EmulatorSession,
                @ViewBuilder framebuffer: @escaping () -> Framebuffer,
                @ViewBuilder overlay: @escaping () -> Overlay) {
        self.session = session
        self.framebuffer = framebuffer
        self.overlay = overlay
    }

    public var body: some View {
        ZStack {
            Color.black
            if session.booting {
                ProgressView("Starting DataRover…").tint(.white).foregroundStyle(.white)
            } else if let error = session.bootError {
                Text(error).foregroundStyle(.white).padding()
            } else {
                framebuffer()
                overlay()
            }
            if session.installing || !session.packageMessage.isEmpty {
                InstallStatusBanner(session: session)
            }
        }
    }
}
```

- `HostHooks.swift` in the package (the protocol only; implementations live in the app targets):

```swift
/// A platform-held assertion that keeps the process alive while a save
/// finishes: an iOS background task, a macOS activity, or nothing.
public final class SaveAssertion {
    public let payload: Any
    public init(_ payload: Any) { self.payload = payload }
}

public protocol HostHooks: AnyObject {
    func beginSaveAssertion() -> SaveAssertion
    func endSaveAssertion(_ assertion: SaveAssertion)
}

/// Default for platforms that are never suspended mid-save.
public final class NoOpHostHooks: HostHooks {
    public init() {}
    public func beginSaveAssertion() -> SaveAssertion { SaveAssertion(()) }
    public func endSaveAssertion(_ assertion: SaveAssertion) {}
}
```

`EmulatorSession.init(nvramDir:cfgDir:packagesDir:romPath:hooks:)` stores `packagesDir` and `hooks` (an overload without `hooks:` defaults to `NoOpHostHooks()` for convenience).

- [ ] **Step 5: Move the artwork and declare the shell target**

Extend `Package.swift` now that its sources and resources exist:

```swift
    products: [
        .library(name: "DataRoverKit", targets: ["DataRoverKit"]),
        .library(name: "DataRoverShell", targets: ["DataRoverShell"]),
    ],
```
```swift
        .target(name: "DataRoverShell", dependencies: ["DataRoverKit", "CDataRoverABI"],
                resources: [.process("Resources")]),
```

Then move the catalog into the shell target's resources directory:

```bash
mkdir -p apple/DataRoverKit/Sources/DataRoverShell/Resources
git mv apple/DataRover/App/Assets.xcassets apple/DataRoverKit/Sources/DataRoverShell/Resources/
```
In `DeviceShellView.swift` and `EmulatorControlsSheet.swift`, every `Image("…")` becomes `Image("…", bundle: .module)` — the three imagesets are `GeneralMagicLogo`, `OptionFace`, `OptionRing`. The app target's `project.yml` source entry `- path: App/Assets.xcassets` is removed in this task, and `App/AppIcon.icon` stays.

- [ ] **Step 6: Build the package**

```bash
cd apple/DataRoverKit && swift build 2>&1 | tail -8 && swift test 2>&1 | tail -6
```
Expected: `Build complete!` and all tests passing. The app target still builds from its own copies (it does not depend on the package yet).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Move the portable logic and shared shell into the DataRoverKit package"
```

---

### Task 4: Cut the iOS app over to the package

**Files:**
- Modify: `apple/DataRover/project.yml` (package dependency; sources; bridging header)
- Modify: `apple/DataRover/App/DataRoverApp.swift` (thin entry + container)
- Modify: `apple/DataRover/App/EmulatorView.swift` (representable only)
- Modify: `apple/DataRover/App/TouchPenView.swift` (touches only)
- Create: `apple/DataRover/App/HostHooks.swift`
- Delete: `apple/DataRover/App/{CoreBridge.swift,CoreBridge.h,ToolbarView.swift}`

**Interfaces:**
- Consumes: everything Task 3 produced.
- Produces: the thin iOS app target that Task 5 verifies; the pattern the macOS app mirrors in stage 2.

- [ ] **Step 1: Add the package dependency and drop the moved files**

In `apple/DataRover/project.yml`:
- add at top level: `packages: { DataRoverKit: { path: ../DataRoverKit } }`
- in `targets.DataRover.dependencies` add `- package: DataRoverKit` with `product: DataRoverShell`
- remove `SWIFT_OBJC_BRIDGING_HEADER: App/CoreBridge.h`
- remove the sources entry `- path: App/CoreBridge.h` (buildPhase none), and remove `- path: App/ToolbarView.swift`

```bash
cd apple/DataRover
git rm App/CoreBridge.swift App/CoreBridge.h App/ToolbarView.swift
xcodegen generate && python3 scripts/inject_mame_sources.py
xcodebuild -project DataRover.xcodeproj -scheme DataRover -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | grep -E "error:|BUILD" | head -20
```
Expected: it fails on the remaining app files referencing moved symbols — that is the next step's work.

- [ ] **Step 2: Rewrite the app's entry and container**

`App/DataRoverApp.swift` keeps `@main struct DataRoverApp: App` with `ROMStore` built from a platform root, plus the container view. Replace the file with:

```swift
// DataRoverApp.swift — iOS entry: platform root, ROM import, device shell.
import DataRoverKit
import DataRoverShell
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let magicCapPackage = UTType(filenameExtension: "pkg", conformingTo: .data)!
    static let magicCapImage = UTType(filenameExtension: "image", conformingTo: .data)!
}

/// iOS keeps the app container's Documents directory as its support root.
func iOSSupportPaths() -> SupportPaths {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return SupportPaths(root: base)
}

@main
struct DataRoverApp: App {
    @StateObject private var romStore = ROMStore(paths: iOSSupportPaths())
    @State private var showImporter = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let romURL = romStore.romURL {
                    EmulatorContainerView(romURL: romURL, paths: romStore.paths)
                } else {
                    VStack(spacing: 16) {
                        Text("DataRover").font(.largeTitle)
                        Text("Import your Magic Cap ROM to begin.")
                        Button("Import ROM…") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                        if let error = romStore.lastImportError { Text(error).foregroundStyle(.red) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .statusBarHidden()
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.magicCapImage, .zip, .data]) { result in
                if case .success(let url) = result { romStore.importROM(url) }
            }
        }
    }
}

struct EmulatorContainerView: View {
    @StateObject private var session: EmulatorSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false
    @State private var showPackageImporter = false
    @State private var importMessage: String?
    private let paths: SupportPaths

    init(romURL: URL, paths: SupportPaths) {
        self.paths = paths
        try? paths.createDirectories()
        _session = StateObject(wrappedValue: EmulatorSession(
            nvramDir: paths.nvram.path,
            cfgDir: paths.cfg.path,
            romPath: romURL.path,
            hooks: iOSHostHooks()))
    }

    private func requestLandscape() { /* unchanged from the current file */ }

    var body: some View {
        DeviceShellView(session: session, openMenu: { showControls = true }) {
            EmulatorBody(session: session,
                         framebuffer: { MetalFramebufferView(session: session) },
                         overlay: { TouchPenView(session: session) })
        }
        .onAppear {
            session.setForeground(scenePhase == .active)
            requestLandscape()
        }
        .onChange(of: scenePhase) { phase in
            session.setForeground(phase == .active)
            if phase == .active { requestLandscape() }
        }
        .onChange(of: showControls) { visible in session.setMenuVisible(visible) }
        .sheet(isPresented: $showControls) {
            EmulatorControlsSheet(session: session, loadPackage: { showPackageImporter = true })
                .fileImporter(isPresented: $showPackageImporter,
                              allowedContentTypes: [.magicCapPackage, .zip, .data]) { result in
                    do {
                        let url = try result.get()
                        showControls = false
                        session.installPackage(url)
                    } catch { importMessage = error.localizedDescription }
                }
                .alert("Package", isPresented: Binding(get: { importMessage != nil },
                                                       set: { if !$0 { importMessage = nil } })) {
                    Button("OK") { importMessage = nil }
                } message: { Text(importMessage ?? "") }
        }
    }
}
```
`requestLandscape()` keeps the current body verbatim from `git show HEAD:apple/DataRover/App/DataRoverApp.swift`. `EmulatorSession.installPackage(_:)` calls `PackageStaging.store(url, into: paths.packages)`, so `EmulatorSession` needs the packages directory: add it to the session's initializer as `packagesDir: String` in Task 3's Shell file (keeping a `paths`-free signature so the Shell stays path-agnostic).

- [ ] **Step 3: Reduce the two leaf adapters**

`App/EmulatorView.swift` becomes the representable only:

```swift
import DataRoverShell
import MetalKit
import SwiftUI

/// Hosts the shared Metal presenter; MTKView exists on both platforms, so the
/// only per-platform part is this representable.
struct MetalFramebufferView: UIViewRepresentable {
    @ObservedObject var session: EmulatorSession

    func makeCoordinator() -> FramebufferPresenter { FramebufferPresenter(session: session) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.setPaused(session.isPaused)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: FramebufferPresenter) {
        coordinator.detach()
    }
}
```

`App/TouchPenView.swift` keeps only `PenView` (the `UIView` subclass) and a coordinator that delegates to `PenRouter`:

```swift
import DataRoverShell
import SwiftUI

/// Single-finger UITouch -> guest pen. The letterbox math lives in
/// DataRoverKit.GuestGeometry via PenRouter.
struct TouchPenView: UIViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> PenRouter { PenRouter(session: session) }

    func makeUIView(context: Context) -> PenView {
        let view = PenView()
        view.router = context.coordinator
        view.isMultipleTouchEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: PenView, context: Context) {}

    final class PenView: UIView {
        weak var router: PenRouter?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            router?.send(.down, point: touch.location(in: self), bounds: bounds)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            router?.send(.move, point: touch.location(in: self), bounds: bounds)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { router?.lift() }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { router?.lift() }
    }
}
```

- [ ] **Step 4: Add the iOS host hooks**

`App/HostHooks.swift`:

```swift
// iOS holds a background task while a checkpoint save finishes; the app is
// otherwise suspended and the save would be cut short.
import DataRoverShell
import UIKit

final class iOSHostHooks: HostHooks {
    func beginSaveAssertion() -> SaveAssertion {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Save DataRover",
                                                                expirationHandler: nil)
        return SaveAssertion(identifier)
    }

    func endSaveAssertion(_ assertion: SaveAssertion) {
        guard let identifier = assertion.payload as? UIBackgroundTaskIdentifier,
              identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
```

- [ ] **Step 5: Build, run, and verify the app is unchanged**

```bash
cd apple/DataRover
xcodegen generate && python3 scripts/inject_mame_sources.py
xcodebuild -project DataRover.xcodeproj -scheme DataRover -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" build 2>&1 | grep -E "error:|BUILD" | head -20
```
Expected: `** BUILD SUCCEEDED **`

Then exercise the flows on the simulator with the ROM fixture already in the container (from Task 1), and confirm by screenshot:
1. Boot shows the calibration crosshair, then the workbench after three taps.
2. The left/right Option rails darken when held and the guest reacts.
3. The logo menu opens the sheet, pausing emulation; Save state reports "State saved"; Restart boots again.
4. Load Package offers a picker and the banner says to open the Storeroom computer.

```bash
DEV=0806B7B8-62A5-4F4A-A7D6-B4D1D2F62423
xcrun simctl install $DEV ~/Library/Developer/Xcode/DerivedData/DataRover-*/Build/Products/Debug-iphonesimulator/DataRover.app
xcrun simctl launch $DEV com.example.DataRover
sleep 25 && xcrun simctl io $DEV screenshot /tmp/stage1-task4.png
```
Expected: the shell renders the guest screen (same pixels as Task 1's screenshot), no white screen, no empty state.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "iOS app: consume DataRoverKit, thin the app target to platform adapters"
```

---

### Task 5: Verify, document, and close out stage 1

**Files:**
- Modify: `docs/apple-shell.md` (renamed from `docs/ios-shell.md` in this task)
- Modify: `PLAN.md` (status line naming the package layout)
- Modify: `apple/DataRover/project.yml` (comment the injection pipeline if the paths moved)

- [ ] **Step 1: Full check pass**

```bash
cd /Users/mattkevan/Dev/magic-cap-emulator
python3 tools/check_core_abi.py
cd apple/DataRoverKit && swift test 2>&1 | tail -6
cd ../DataRover && xcodegen generate && python3 scripts/inject_mame_sources.py
python3 - <<'EOF'
import subprocess, difflib
head = subprocess.run(["git","show","HEAD:apple/DataRover/DataRover.xcodeproj/project.pbxproj"],capture_output=True,text=True).stdout
cur = open("DataRover.xcodeproj/project.pbxproj").read()
d=[l for l in difflib.unified_diff(head.splitlines(),cur.splitlines(),lineterm="") if l[0] in "+-" and l[:3] not in ("+++","---")]
print("regeneration diff lines:", len(d))
EOF
```
Expected: ABI check passes, tests pass, and the regeneration diff is 0 lines (the committed pbxproj is what the pipeline produces).

- [ ] **Step 2: Document the shared layout in the existing shell document**

`docs/ios-shell.md` keeps its name until stage 2 (where the macOS section makes `docs/apple-shell.md` accurate). Add a section describing the new tree: the shared layer is `apple/DataRoverKit` (`CDataRoverABI` declarations, `DataRoverKit` pure logic with `swift test` coverage, `DataRoverShell` ABI/session/UI); the iOS app target is a thin adapter; and which files moved where (`CoreBridge.{h,swift}`, `ToolbarView.swift`, the Metal coordinator, the pen geometry, the asset catalog). Leave the existing iOS-specific findings (background saving, landscape, iPad clipping caveat) intact.

- [ ] **Step 3: Note the stage in PLAN.md**

Add one line to the status section: the Apple apps share `apple/DataRoverKit`; stage 1 (extraction) is complete; the macOS target is stage 2.

- [ ] **Step 4: Commit and push**

```bash
git add -A
git commit -m "Document the shared package layering; close stage 1"
git push origin main
```

---

## Verification summary (stage 1)

| Check | Command | Expected |
|---|---|---|
| ABI drift | `python3 tools/check_core_abi.py` | copy matches the fork header |
| Pure logic | `cd apple/DataRoverKit && swift test` | all suites pass |
| Project regeneration | `xcodegen generate && python3 scripts/inject_mame_sources.py` | 0-line diff vs committed pbxproj |
| iOS app | build + install + launch on iPhone 17 Pro | shell renders, ROM boots to calibration → workbench |
| Core untouched | `git diff --stat HEAD~4 -- apple/DataRover/Core` | empty |