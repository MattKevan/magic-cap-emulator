# DataRover iOS shell — design

Scope: Xcode project + SwiftUI shell + static-lib core, sideload dev
build. Pen + power/option buttons + software keyboard. Approach: new
SwiftUI shell over the core ABI (MAME4iOS shape, no 0.139 baggage).

Rejected: (2) port MAME4iOS ObjC frontend — tied to 139-era OSD/input
APIs, fights the 2026 tree. (3) SDL-iOS backend — SDL-shaped UX, no
native toolbar/Files.

## Xcode project

`ios/DataRover/` — `DataRoverCore` static lib (SUBTARGET=datarover
file set, `-miphoneos-version-min`, headless OSD stub, no SDL) +
`DataRover` app target (iOS 16+, arm64 + simulator). Sideload
signing (free Apple ID, personal team). No GENie work. Link closure
is 27 real MAME symbols (15 frontend/manager + 12 driver/devices;
`.superpowers/sdd/ios-build/link-closure.md`); 58 toolchain symbols
come free.

## Framebuffer view

`MTKView` blitting the 480×320 2bpp buffer via
`datarover_framebuffer_bytes` per frame, null-checked per the header
contract. Aspect-fit scaling.

## Input

- Touch → `datarover_pen_down/move/up`, 480×320 mapping, single
  finger (MAME4iOS multi-touch gun pattern is reference only).
- Toolbar: Power, Option Button (same pulse semantics as mac).
- Software keyboard: `UIKeyInput` bridge into a new core ABI
  key-injection function (small addition, specified at
  implementation).

## Files

ROM + `.pkg` import via `fileImporter` (security-scoped) into the
app container; installs via `datarover_install_package_named`
(handshake complete: Cnct/Cntd×2/SPkg/Pong/GBye). ROM stays
user-supplied (guideline 4.7 shape for later store submission).
Flag: iOS sandbox may block PTY at runtime — install may need a
non-PTY RS-232 backend; diagnosed at device-test time, not solved
here.

## Verification

Sideload → boot to calibration → touch calibrates → install
DvorakKeyboard → suspend/wake. Same acceptance as mac, on device.
