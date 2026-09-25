# Apple app networking, HTTPS, and audio — design

Date: 2026-09-25. Status: approved design; implementation plan pending.

## Goal

Complete guest networking, HTTPS browsing, and speaker playback in both Apple
apps: the iOS/iPadOS app and the sandboxed macOS app. Keep the implementation
shared where possible, and use the emulator's existing device behavior rather
than adding a second guest-side networking or audio model.

Audio scope is playback only. Microphone capture, phone call routing, modem
audio input, clock sync, contacts, calendar, Notes, and package installation
are outside this work. Package installation already uses the in-process PCLink
channel in both apps.

## Current project state

- The MAME fork already contains `src/osd/modules/netdev/slirp.cpp`, an Ethernet
  provider backed by libslirp. It is not included in the Apple source list and
  the app core does not currently select `3c589` or the `slirp` provider.
- The headless OSD currently exposes no network devices, reports `no_sound()`,
  and discards sound output samples. Its sound interface already has a sink
  update callback, which is the boundary for host playback.
- The project has deterministic EtherLink HTTP and HTTPS regressions. The
  HTTPS harness currently starts an external `carl` helper and a loopback
  listener; app integration must not depend on either process.
- `DataRoverShell` is shared between iOS and macOS. The app targets use the
  same core source list generated from `apple/DataRover/Core/file-list.txt`.
- The macOS app already has the sandbox network-client entitlement. The
  iOS/macOS core creation ABI currently accepts paths only, so app-selectable
  networking needs an explicit configuration path.

## Architecture

### 1. Guest IPv4 networking

Use MAME's existing libslirp network provider on both platforms. Configure the
emulated 3Com EtherLink III PC Card and the `slirp` provider when the user
enables networking. Preserve the established guest network convention:
`10.0.2.15` for the guest, `10.0.2.2` for the host-side service address, and
`10.0.2.3` for DNS.

Build pinned static dependencies for iOS device arm64, iOS simulator arm64,
and macOS arm64, then combine Apple platform slices into build products for
the Xcode targets. The build must be reproducible from scripts and source
versions; generated archives/frameworks stay out of Git. Include required
license notices. Add the existing MAME provider source and compile definition
to both Apple core builds, and make the headless OSD enumerate the provider.
Expose an initial network setting through the core creation configuration and
the app UI. Changes apply on the next core restart. When disabled, the guest
does not get the EtherLink card or a host network path.

No custom TCP/IP stack or external bridge process will be introduced. This
chooses a larger native dependency build over maintaining an app-specific
Ethernet, ARP, IP, DNS, and TCP implementation. libslirp's callback and poll
integration matches the MAME provider already in the fork.

### 2. In-app HTTPS proxy

Implement one shared proxy service in `DataRoverShell`, using
Network.framework for its loopback listener and TLS client connections. The
proxy listens only on host loopback at the port configured by the guest's
existing Magic Cap Web Browser Rule 14 setup. libslirp's host-loopback mapping
lets guest connections reach that listener via `10.0.2.2`.

For each connection, parse one bounded absolute-form HTTPS request, validate
the method, target, headers, and body length, connect to the requested host
with TLS, and relay the response. Use the platform trust store and validate
the certificate chain and hostname. Do not implement CONNECT or arbitrary
proxy tunneling. Refuse private, loopback, link-local, and reserved Internet
destinations in normal app operation. Impose request/header/body limits,
connection deadlines, a concurrency cap, and close each transaction cleanly.

Provide explicit test-only trust and loopback-destination exceptions for the
deterministic HTTPS fixture, compiled or injected only in the acceptance
configuration. They must not weaken release certificate validation or
destination restrictions. Keep the original request available to the test
harness so acceptance proves that the guest issued the HTTPS Rule 14 request,
the in-app proxy opened a TLS connection, and the decrypted response rendered
on the guest display.

### 3. Guest speaker playback

Replace the OSD's null sound sink with a host audio bridge while preserving
MAME's guest sound generation and volume behavior. The core receives output
samples from MAME's sink callback and writes them into a bounded,
preallocated producer/consumer queue. The audio render callback reads samples
without blocking or allocating; it emits silence on underrun and drops
incoming samples if full.

Use a shared AVFAudio `AVAudioEngine` source node in `DataRoverShell` to pull
the queued samples into the current host output route. Keep format conversion
and channel handling explicit at the bridge boundary. Start playback after
core/audio initialization, clear queued samples on restart, and stop or mute
the output while the emulator is paused or backgrounded. Microphone input is
not opened and no microphone usage permission is requested.

## UI and lifecycle behavior

- Add a Network setting to each app, off by default until enabled by the user;
  changing it records the desired state and takes effect after restart.
- Surface whether the network backend initialized. If the bundled backend is
  unavailable, keep the app usable and report the network failure rather than
  silently claiming connectivity.
- Keep the proxy lifecycle tied to the active emulator session. Stop it during
  teardown; reestablish it when the app returns to the foreground if needed.
- Audio follows the host's normal route and system output volume. Audio engine
  start failures degrade to silence and are surfaced as a playback status.
- Pausing, opening a blocking menu, backgrounding, restarting, and destroying
  the core must not leave a live proxy listener or stale audio queued.

## Failure handling and privacy

Networking is opt-in because it grants the guest outbound connectivity through
the host. It uses user-mode NAT rather than exposing a host interface. The
proxy only accepts guest requests on loopback and only handles HTTPS requests
that satisfy the proxy policy. Certificate errors and blocked destinations
return a useful guest-readable HTTP error; they do not disable TLS checks.
Logs must not record full URLs, credentials, headers, or response bodies.

If dependency loading, network initialization, TLS connection, or audio startup
fails, report the failed capability independently; do not fail emulator boot.
Guest app suspension may interrupt open network flows, so foreground resume
must permit clients to reconnect.

## Acceptance

1. Both Apple core targets link the same libslirp provider and boot with
   networking disabled and enabled.
2. On iOS simulator and macOS app, the existing EtherLink regression reaches
   the configured guest network, completes ARP/TCP/DNS as applicable, and
   renders the deterministic HTTP response.
3. On iOS simulator and macOS app, the guest's Rule 14 request passes through
   the in-app proxy; a test-only trusted local TLS endpoint receives the exact
   expected request; valid public certificates pass; invalid certificates,
   malformed requests, disallowed targets, and oversized requests fail
   closed.
4. Guest sound produces audible output through host speakers/headphones on
   both apps; MAME sound controls still mute and adjust output. Pause,
   background, restart, and teardown stop or clear output without blocking
   the emulation thread.
5. Backend/proxy/audio startup failures do not prevent the guest from booting.
   Existing emulator regression behavior remains unchanged.

## Implementation boundaries

Changes span this repository's Apple project, shell and regression harnesses,
plus the sibling `mame` fork's core OSD/network integration. The sibling fork
may already contain unrelated uncommitted edits; implementation must preserve
them and commit only task-owned changes. Publish only to the configured
`MattKevan` remotes.

## Research references

- [Apple Network framework](https://developer.apple.com/documentation/network)
  provides TCP connections and listeners used by the in-app proxy.
- [Apple AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
  and [AVAudioSourceNode](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode)
  provide host real-time output from supplied PCM samples.
- [libslirp integration documentation](https://gitlab.freedesktop.org/slirp/libslirp/-/blob/master/_autodocs/README.md)
  describes embedding, callbacks, and event-loop polling. The MAME fork's
  existing `netdev/slirp.cpp` is the implementation selected for reuse.
