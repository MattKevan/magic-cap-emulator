# DataRover shared core (mac/iOS) — design

Scope: extract the driver into a portable `libdatarover` core with a C
ABI, serving a mac SwiftUI shell now and an iOS SwiftUI shell next.
Approach A (core/frontend separation, the OpenEmu/MAME4iOS/UTM shape).

Rejected: (B) portable SDL for both — cheaper, but iOS stays
SDL-shaped (no native toolbar/Files/Settings) and the menubar work
doesn't transfer. Fails the native ask.

## Core ABI

C interface over the extracted driver (TX39 + Dino/Betty + 3C589 +
NVRAM):

- `datarover_create/destroy` — lifecycle.
- `set_framebuffer_callback` — 480×320 2bpp publisher; frontend
  uploads to Metal. Pixel-compare vs SDL build is the acceptance.
- `pen_down/move/up` — maps to the existing absolute gun path
  (`System pointer gun`, `input_sdl3.cpp:2166`); finger events
  (`osdsdl.cpp:673`) on iOS.
- `install_package(bytes)` — in-process PCLink wire codec (reuse
  `tools/pclink_send.py` logic; `ChMa`/CRC/`Ping`/`Pong`/`GBye`).
- `pump_network frames` — 3C589 → slirp/peer (`docs/etherlink.md`).
- Paths injected by the frontend: NVRAM/cfg/packages (Application
  Support on mac, app container + Files on iOS). ROM stays
  user-supplied everywhere.

## Mac frontend

SwiftUI `WindowGroup` + `.toolbar` + `Commands` + `Settings` +
`fileImporter` for `.pkg`/ROM; Metal view for the framebuffer;
network toggle (`-pccard1 3c589` equivalent via core config) + host
TLS proxy (existing `https_proxy.py` pattern as bundled helper).
SDL shell retires once the SwiftUI shell reaches parity.

## iOS frontend

Same core, new shell: touch view (finger → pen), Files/AirDrop
import for `.pkg`/ROM (MAME4iOS pattern), sideload first with a free
Apple ID. App Store later under guideline 4.7 (emulators permitted
since April 2024) with user-supplied ROM/packages. Open risk: TX39
DRC/JIT correctness on arm64 (MAME4iOS notes arm64 DRC crashes) —
verify early.

## Staging

1. Extract core behind the ABI with the SDL frontend still working
   (no UX change, regressions green) — the safety net.
2. Mac SwiftUI shell to parity (toolbar, Commands, Settings,
   fileImporter, Metal blit, network toggle + proxy).
3. iOS shell + arm64 DRC check + sideload.

## Verification

Per stage: framebuffer pixel-compare vs SDL build, pen round-trip,
package install (DvorakKeyboard lands in Storeroom), EtherLink HTTP
render (`EtherLink III works`) — the same acceptance as today, on
two frontends. Existing regression suite stays green throughout;
no emulation behavior changes.
