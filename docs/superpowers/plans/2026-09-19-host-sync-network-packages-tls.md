# Host sync, networking, packages and HTTPS on macOS/iOS

Date: 2026-09-19. Status: proposed, not started.

## What was asked

Close four gaps in the native shells (macOS `.app` and iOS app), which today can
boot the guest but cannot do the things a user actually wants:

1. **Clock** — Magic Cap's date and time should follow the host clock on both
   platforms, across boot, backgrounding/foregrounding and host clock changes.
2. **Network** — the guest's networking (EtherLink III path) should work inside
   the apps, not only from the Linux/macOS CLI harness.
3. **Package loading** — installing a `.pkg` into the guest from the app's own
   file picker, on iOS as well as macOS.
4. **HTTPS** — browsing `https://` pages from the guest through the app.

## Where the code is today

**Clock.** The guest RTC is a 40-bit counter ticking at 32,768 Hz with no epoch
(`datarover.cpp:3081` `rtc_ticks()`; registers at `datarover.cpp:3929-3933`).
Host time enters in exactly two places: a 20-byte `DRTC` NVRAM record holding
`{ticks, host unix seconds}` (`datarover.cpp:3130-3144`), and a warm-boot resume
that advances the counter by elapsed host seconds when the `RTC_RESUME` port is
set (`datarover.cpp:4616-4634`, port at `:4735`). A MAME checkpoint restores the
counter verbatim, so time spent paused is dropped — already noted in
`docs/ios-shell.md:27-33`. The only known software path that *moves* the counter
is the IDT monitor's `SetTimer` (`tools/rtc_set_regression.py`, entry
`0x13c04f04`, timer-control test bits 0/1, 4-tick tolerance).

**Network.** Every guest connectivity path terminates in host-side tooling: PTY
slaves, a bitbanger socket, or pcap/TAP/libslirp behind Python bridges
(`docs/modem.md`, `docs/builtin-modem.md`, `docs/etherlink.md`,
`docs/pclink.md`). The shared `libdatarover` core the apps use exposes **no**
network devices, and forces `rs2321` to `null_modem` because the iOS sandbox
denies `/dev/ptmx` (`datarover_core.cpp:636-642`). The iOS target already
compiles `netdev_common/none/pcap/taptun/udp`, but **not** `slirp.cpp`
(`ios/DataRover/Core/file-list.txt:1085-1089`); `libslirp` is supplied by
Homebrew on macOS (4.9.4) and exists nowhere in the MAME tree.

**Packages.** The core already has the ABI (`datarover_install_package`,
`datarover_install_package_named` in `datarover_core.h:36-40`) and a complete
PCLink codec, but the install path is hard-wired to a PTY slave path that iOS
cannot create. Swift never calls it: the iOS Import button copies the file into
`Documents/packages` and reports "not installed" (`ios-shell.md`). An
in-process byte channel exists uncommitted — `host_serial.h` plus the
`null_modem::set_host_channel` hook — with **no callers**.

**HTTPS.** The guest browser uses Rule 13/14 proxies, sending absolute URLs to a
host proxy that performs TLS; TLS deliberately lives on the host
(`docs/oldvcr-tls.md`). Today that proxy is the external `carl` binary driven by
`tools/https_proxy.py`, reachable only because EtherLink III + libslirp give the
guest `10.0.2.2`. It requires the one-byte-patched browser
(`tools/patch_tls_browser.py`), does not validate certificates, and cannot be
forked on iOS.

## Guiding decisions

- **All app-side transports become in-process.** PTY, pcap, TAP and `fork`/`exec`
  are unavailable or hostile in the iOS sandbox; one in-process design serves
  both platforms and removes the launcher's PTY scraping contract.
- **TLS terminates in the app**, not in a spawned helper, so iOS can do HTTPS at
  all. Keep the guest→proxy hop on the emulated network.
- **Reuse the existing acceptances** rather than inventing new ones:
  `tools/pclink_regression.py` (461,876-byte package, final `Pong`/`GBye`),
  `tools/https_proxy_regression.py` (`https://localhost` → decrypted
  `GET / HTTP/1.0` → rendered page), `tools/etherlink_peer.py` (ARP/DNS/TCP/HTTP).
- **Guest date is the risky half of clock sync.** The tick counter has no epoch,
  so "correct ticks" ≠ "correct date". Locating a guest date setter is an
  investigation with a fallback, not a known work item.

## Phases

Dependency order. Phase 4's investigation is independent and may run alongside
Phase 0.

### Phase 0 — In-process serial transport

*Target:* one byte channel between `libdatarover` and the emulated RS-232 card,
no PTY.

*Change:* finish and commit `src/devices/bus/rs232/host_serial.h` and the
`null_modem` hook in the MAME fork; construct the channel in `datarover_core`
and call `set_host_channel` on the boot-cached `rs2321` card on the emulation
thread (the slot is already cached at `datarover_core.cpp:444-447`); repoint the
install handshake from the PTY slave path to the channel; keep `null_modem`
forced on iOS and make it the default everywhere the core is used.

*Acceptance:* on macOS and the iOS simulator, the pinned 461,876-byte browser
package installs end to end — final `Pong`, `GBye`, 454K Storeroom object, zero
`MagicBus_HandleMagicBusFailure` calls. Reproduce with
`tools/pclink_regression.py` against the in-process transport.

### Phase 1 — Package loading in both apps

*Target:* a user picks a `.pkg` in the app and it lands in the guest.

*Change:* iOS gets a real call to `datarover_install_package_named` from
`CoreBridge.swift` (the bridging header already redeclares it), with
security-scoped document-picker access, storage under `Documents/packages`, a
progress/busy state and distinct failure reporting; the "not installed" stub and
its footnote are deleted. macOS routes its existing Install Package menu through
the same core call (in-process, from Phase 0), and `packaging/macos/launcher.sh`
drops the PTY announcement/scraper path once nothing depends on it.

*Acceptance:* install the same pinned package from the iOS simulator UI and from
the macOS `.app` menu; guest Storeroom shows the object without an alert;
relaunch keeps it.

### Phase 2 — Network in the apps

*Target:* the guest gets a working EtherLink III network inside both apps.

*Change:* expose the network provider and the PC Card option through the core's
create options (`datarover_create` currently takes dirs + ROM only), so the app
can request `3c589` + `slirp`. Then make libslirp available per platform: macOS
links the Homebrew `libslirp` (as the CLI build already does) and bundles it
into the `.app`; iOS needs `libslirp` **and its GLib dependency** cross-compiled
for arm64 device + simulator, with `slirp.cpp` added to `file-list.txt` and
`OSD_NET_USE_SLIRP=1` in the target defines. The headless OSD currently returns
no network devices and must hand back the real provider list. The fallback, if
the GLib cross-compile proves unreasonable, is an in-app IPv4/TCP peer over the
existing privilege-free `udp` netdev provider (`netdev/udp.cpp`, already in the
iOS file list).

*Acceptance:* the existing deterministic EtherLink acceptance (ARP/TCP complete,
local HTTP renders) runs from the iOS simulator and the macOS `.app`, not just
from the CLI.

### Phase 3 — HTTPS in the apps

*Target:* `https://` in the guest browser with no external helper binary.

*Change:* implement the forward proxy inside the app — loopback listener,
absolute-form `https://` requests only, TLS via Network.framework (iOS) /
Network.framework or SecureTransport (macOS) — replacing the spawned `carl`
process while keeping its guardrails: no `CONNECT`, loopback-only bind, request
limits and deadlines, concurrency cap, private/link-local destination refusal.
Unlike `carl`, validate server certificates. Ship the patched browser package
through the existing asset fetch (`tools/patch_tls_browser.py`), never in Git.

*Acceptance:* the deterministic HTTPS regression's success conditions hold from
the app: native Rule 14 request captured, TLS endpoint independently decrypts
the exact `GET / HTTP/1.0`, the rendered page appears on the guest screen.

### Phase 4 — Host clock and date sync

*Target:* the guest shows the host's date and time, and keeps it across pause,
backgrounding and clock changes.

*Change:*
- **Tick continuity first (known ground).** Extend the `DRTC` record handling so
  a checkpoint restore advances the counter by elapsed host wall time, reusing
  the warm-boot logic at `datarover.cpp:4616-4634`. This fixes paused/backgrounded
  time without touching guest-visible semantics.
- **Absolute date (investigation).** Find the guest's date/time setter: ROM
  `DateTimeUnitTests__Fv` (`docs/dev-rom.md:224-237`), the SDK headers inside
  `magic-cap-assets/sdk/Datarover840.zip`, and the monitor `SetTimer` path are
  the leads. Then add a core call (e.g. `datarover_set_guest_datetime`) that the
  apps invoke at boot, on foreground/wake, on host clock change
  (`NSSystemClockDidChange`/`significantTimeChangeNotification`) and after a
  checkpoint restore. Timezone and DST are part of this step, not an afterthought.
- **Fallback if no setter exists:** sync ticks only and set the date once
  through the guest's own UI path if one is reachable by synthetic input;
  document the residual limitation rather than writing host seconds into the
  RTC, which is meaningless for a counter with no epoch.

*Acceptance:* guest date/time matches the host after boot; advancing the host
clock by an hour while the app is backgrounded leaves the guest correct on
return; a checkpoint resume after N minutes of pause shows N minutes elapsed.

### Phase 5 — Integration

Switches in both apps for network/HTTPS with their failure modes surfaced;
`docs/` updated (`ios-shell.md`, `oldvcr-tls.md`, `mame-bringup.md`); the new
acceptances wired into `tests/`; macOS CLI/Linux parity preserved.

## Risks

- **Guest date setter may not exist** in a reachable form → Phase 4's absolute
  half degrades to tick-only sync. Highest-uncertainty item; investigate early.
- **GLib for iOS** is the heaviest build dependency introduced by Phase 2.
- **libslirp licences**: libslirp and GLib are permissively licensed, but the
  cross-compiled artefacts and the patched browser package stay out of Git.
- **Redistribution**: the modified browser package is third-party and
  no-warranty; keep it a fetched asset.
- **iOS lifecycle**: background suspension means every host-time and network
  assumption must be re-established on foreground, not merely at boot.

## Findings (2026-09-19, first implementation pass)

Phase 0's code is in place and builds for the iOS simulator and app: an
`rs232_host_channel` (mutex-guarded byte deques) is created with the core,
handed to the `null_modem` card on the emulation thread, and the PCLink
handshake now runs over it, preferring the channel and falling back to the PTY
slave. The core also exposes phase-granular `datarover_install_progress` and
`datarover_emulated_seconds` (the latter verified to track wall time 1:1 under
throttling), and the iOS app calls the install API with progress instead of
reporting "not installed".

**The transfer does not complete, and the blocker is guest-side, not in the
channel wiring:**

- With `null_modem` in the slot, the guest never writes a byte to UART A —
  instrumenting `datarover_state::uart_transmit` and the card's receive path
  showed zero transmissions across a full 180 s handshake window, while the
  channel was confirmed wired (`:rs2321:null_modem`, `channel=1`).
- The guest shows its own "your communicator can't link to a computer" dialog
  in the *unmodified CLI* too, when that harness is run with
  `-rs2321 null_modem` and no host attached — so the behaviour is independent
  of this work.
- The driver wires only TXD/RXD between the UART and the slot
  (`datarover.cpp:4862-4866`); it sets no `dcd_handler`/`dsr_handler`/
  `cts_handler`, and `datarover_uart_device` is a plain
  `device_buffered_serial_interface` with no modem-status register. Asserting
  DCD/DSR/CTS from the card therefore cannot be what the guest waits for, and
  an attempt to do so changed nothing.
- The guest does transmit over the `pty` card: the CLI regression captures its
  1089-byte opening exchange.

Candidate causes to isolate next, cheapest first: (1) rebuild the CLI with the
same instrumentation and run it with `null_modem` *and* the working Lua, to
separate card type from environment; (2) give the iOS core the harness's
deterministic `MAGICBUS_ACCESSORY` configuration, since the driver warns the
ROM counts unanswered Magic Bus assignment as a peripheral failure;
(3) determine whether the guest's link path needs the IrDA PTY, which opens on
macOS but not on iOS (`datarover_irda_device::device_start` returns early).

Until one of those lands, the iOS and macOS apps attempt the install and
report the guest's refusal rather than a false success — which is still a
strict improvement over the previous behaviour, where the core had no slave
path at all and returned failure immediately.

## Open decisions

1. Phase order — start with the clock investigation (user's first-listed ask)
   or with Phase 0/1, which unblock two of the four asks at once?
2. iOS network backend — cross-compile libslirp + GLib (fidelity with existing
   regressions, heavier build) or an in-app peer over the UDP netdev provider
   (no new dependency, more code to maintain)?
3. macOS HTTPS — in-app TLS proxy on both platforms as above, or keep the `carl`
   helper on macOS and implement the proxy only for iOS?
