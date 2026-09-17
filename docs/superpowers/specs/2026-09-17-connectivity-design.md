# DataRover connectivity — design

Scope: File → Install Package… (phase 1, this spec), Network toggle +
guest setup (phase 2, same design), Device buttons + Right-Alt remap
(bounded companion). Cocoa menubar only; no SwiftUI (see Alternatives).

## Approach

Menu-driven host agent. File → Install Package… picks a `.pkg` via
`NSOpenPanel`; a host agent extracted from `tools/pclink_regression.py`
speaks the recovered PCLink wire format over the running machine's
`-rs2321 pty` PTY while the user holds the Storeroom computer open.
Manual guest navigation (user choice); no Lua automation in the bundle.

Rejected: (2) script-only manual runs — violates install-first scope.
(3) all-at-once with modem/PPP — needs classic Slirp + Bubblewrap,
Linux-only; EtherLink + libslirp is the mac-viable route.

## Phase 1 — Install Package

- Menu: File → Install Package… (`NSOpenPanel`, `.pkg` filter,
  default dir `~/Library/Application Support/DataRover/packages/`).
- Agent: new `tools/pclink_send.py`, extracted from the regression
  harness: `ChMa` handshake, CRC stream, `Ping`/`Pong` barrier,
  `GBye` close (`docs/pclink.md`, `tools/pclink_regression.py:210-320`).
- Transport: running machine must expose `-rs2321 pty`; agent reads
  the PTY path from MAME stdout (`:rs2321:pty PTY:` pattern,
  `pclink_regression.py:36`) and feeds the picked file.
- Result: package object appears in Storeroom; progress via Ping/Pong.
- ROM stays user-supplied; packages live in Application Support.

## Phase 2 — Internet

- Blocker: mac binary has no slirp provider (`-networkprovider slirp`
  → "not supported"; no libslirp linkage). Linux auto-detects; mac
  needs `USE_SLIRP=1` rebuild (brew libslirp 4.9.4 + pkg-config
  present — verified).
- Menu: Network toggle passing `-pccard1 3c589 -networkprovider
  slirp` (restart required); guest `10.0.2.15`, host `10.0.2.2`.
- Guest setup is manual: Internet Center provider + EtherLink driver
  and browser installed via Phase 1 (`docs/etherlink.md`,
  `docs/oldvcr-tls.md`).
- HTTPS via host TLS proxy only (existing `https_proxy.py` pattern);
  no guest crypto. Modem/PPP path stays out (Linux-only).

## Device buttons + remap

- Physical set is two buttons (`datarover.cpp:4649-4768`): power
  (`End` today, suspend/wake) and Option (Left Alt today, card
  erase/setup flows).
- New Device menu: Power (`⌘P`, keeps `End`), Option Button
  (hold-able or toggle).
- Pointer-release moves Left Alt → Right Alt: Left Alt is both the
  Option button and the release modifier today, so Alt-release also
  presses Option — harmless on the desk, wrong during card ops.

## Alternatives considered — SwiftUI

User asked for a SwiftUI toolbar and SDL-in-SwiftUI hosting. Rejected
for this scope: SDL owns the event loop, window lifecycle and input
grab; SwiftUI owns layout and window management. Hosting one inside
the other (`NSViewRepresentable` around SDL, or `SDL_CreateWindowFrom`
an `NSView`) gives two owners for focus/resize/keys/fullscreen —
the grab/focus bugs already fought in `sdl3/window.cpp`. Best
practice (OpenEmu, MAME4iOS, UTM, Dolphin) is core/frontend
separation: `libdatarover` + SwiftUI shell + Metal blit of the
480×320 framebuffer — a weeks-to-months v2, staged after this work.

## Verification

- Install: real `.pkg` (DvorakKeyboard) lands in Storeroom on the
  running app; bad file rejected.
- Internet: EtherLink regression path green + guest browser renders
  local HTTP.
- Buttons: suspend/wake cycle + Option-insert flow via menu.
- Existing regression suite stays green.
