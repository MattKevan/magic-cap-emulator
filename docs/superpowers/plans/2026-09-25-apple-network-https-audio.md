# Apple network, HTTPS, and audio implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cross-platform guest Internet access, HTTPS browsing, and speaker playback to the iOS and macOS apps.

**Architecture:** Reuse MAME's existing libslirp EtherLink provider, expose configuration and capability status through the core ABI, and serve Rule 14 requests through one shared Network.framework proxy. Feed MAME PCM output through a bounded C++ queue into an AVAudioEngine source node in `DataRoverShell`.

**Tech Stack:** MAME/libslirp/GLib, C/C++ ABI, Swift, Network.framework, AVFAudio, XcodeGen.

---

## File map

### Sibling MAME fork (`../mame`, remote `MattKevan/mame`)

- `src/libdatarover/datarover_core.h/.cpp` — add network/audio options, expose provider initialization status, replace forced silence, and add bounded PCM pull API. The working tree already contains user changes in these files; retain those hunks and edit only alongside them.
- `src/osd/modules/netdev/slirp.cpp` — existing provider to compile without behavior changes unless platform portability requires a narrow fix.
- `src/mame/skeleton/datarover.cpp` — guest 3C589 configuration is already present; the file currently has an unrelated user include edit, which must be preserved.
- A new focused core regression source may be added only if the user requests automated tests; do not add or run tests during this implementation.

### This repository (`magic-cap-emulator`, remote `MattKevan/magic-cap-emulator`)

- `apple/DataRover/Core/file-list.txt` — compile `netdev/slirp.cpp` into iOS and macOS core targets.
- `apple/DataRover/project.yml` — add `OSD_NET_USE_SLIRP`, static dependency search paths and libraries, plus the Network and AVFAudio framework flags on the relevant targets. No privacy usage description is needed because this scope opens neither the microphone nor a local-network interface. The generated `project.pbxproj` is already modified by the user; preserve those existing scheme/project settings and apply only generated source/link changes.
- `apple/DataRover/scripts/build_apple_network_deps.sh` plus `apple/DataRover/Dependencies/` — fetch pinned libslirp/GLib source revisions, build static arm64 dependencies for device, simulator, and macOS, and stage ignored archives/headers plus licenses under `build/apple-network-deps/`. No built artifacts are committed.
- `apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h` — mirror the core ABI additions exactly.
- `apple/DataRoverKit/Sources/DataRoverShell/CoreHandle.swift` — typed wrappers for network option/status and audio pull.
- `apple/DataRoverKit/Sources/DataRoverShell/HTTPSProxy.swift` — loopback HTTP parser, policy, NWListener/NWConnection lifecycle, TLS relay.
- `apple/DataRoverKit/Sources/DataRoverShell/HostAudioOutput.swift` — AVAudioEngine source node and core PCM pull coordination.
- `apple/DataRoverKit/Sources/DataRoverShell/EmulatorSession.swift` — own proxy/audio lifetimes and capability statuses; accept desired network preference at creation.
- `apple/DataRoverKit/Sources/DataRoverShell/DeviceShellView.swift` and `EmulatorControlsSheet.swift` — shared UI for network preference, restart instruction, and capability errors.
- `apple/DataRover/Mac/DataRoverMacApp.swift` and `apple/DataRover/App/DataRoverApp.swift` — load/persist per-app network preference and pass it to the shared session.
- `docs/apple-shell.md`, `docs/oldvcr-tls.md`, and `docs/mame-bringup.md` — document setup, bundle building, and app acceptance after implementation.

## Task 1: Build reproducible Apple libslirp dependencies

- [ ] Pin the libslirp and GLib source revisions in the dependency script; fetch source archives by HTTPS and verify fixed SHA-256 hashes before extraction.
- [ ] Build static arm64 GLib and libslirp for `iphoneos`, `iphonesimulator`, and `macosx`, with only POSIX/socket functionality enabled; emit headers, static archives, pkg-config metadata, and upstream license files beneath ignored `build/apple-network-deps/{platform}` directories.
- [ ] Make the script fail with a specific error if any configure, compile, or archive step fails; do not install dependencies globally or modify Homebrew state.
- [ ] Add `build/apple-network-deps/` to `.gitignore` and document the single invocation `apple/DataRover/scripts/build_apple_network_deps.sh`.

## Task 2: Wire the libslirp provider into both app cores

- [ ] Add `src/osd/modules/netdev/slirp.cpp` to `apple/DataRover/Core/file-list.txt`; add `OSD_NET_USE_SLIRP` and generated dependency include/library paths to both core targets in `project.yml`.
- [ ] Extend `datarover_create` with a versioned options struct while preserving the existing three-path ABI as a wrapper that passes default options. Options include `network_enabled` and the reserved `audio_output_enabled` flag. Update `CoreBridge.h` and `tools/check_core_abi.py` expectations in lockstep.
- [ ] When network is requested, set MAME's `pccard1=3c589` and `networkprovider=slirp` before machine configuration; when disabled, leave the PC Card absent. Return a clear status if the provider cannot be created, without failing machine boot.
- [ ] Replace the headless OSD's empty `list_network_devices` with enumeration/open behavior compatible with MAME's `osd_common_t` conventions so `slirp.cpp` can be selected by the machine's network device.
- [ ] Preserve MAME user edits in `datarover_core.cpp` and `datarover.cpp`; inspect `git diff` before staging to ensure those edits are not accidentally included in task commits.

## Task 3: Surface network preference and status in both apps

- [ ] Add a small `NetworkSettings` value to `DataRoverKit` that reads/writes the existing app support preferences location and defaults to disabled.
- [ ] Pass the preference through both app entry points into the new create-options ABI; show a Network switch in the shared controls sheet and state that changing it requires restart.
- [ ] Surface the core's provider initialization status on the controls sheet. A failed provider must leave the guest booted and display a concise actionable status.
- [ ] Ensure restart uses the saved desired setting and that background/foreground only pauses/resumes the session; do not silently change the user's preference.

## Task 4: Implement the shared HTTPS proxy

- [ ] Add a parser that accepts exactly one bounded HTTP/1.x absolute-form request with `https` scheme, `GET`/`HEAD`/`POST`, consistent Content-Length, and no Transfer-Encoding, credentials, or fragment. Return deterministic HTTP errors for invalid or unsupported requests.
- [ ] Add `HTTPSProxy` with an NWListener bound exclusively to `127.0.0.1`, a fixed documented guest-configured port, a bounded accepted-connection count, per-request deadline, and clean cancellation.
- [ ] Use `NWConnection` with TLS and default system trust evaluation; require hostname validation, forbid CONNECT, resolve destinations before connecting, and reject IPv4/IPv6 loopback, private, link-local, multicast, and reserved ranges in release operation.
- [ ] Relay request and response bytes without logging URLs, headers, credentials, or bodies. Stop the listener when the session is destroyed and restart it on foreground only if the session remains alive.
- [ ] Add an acceptance-only proxy policy injected at initialization that allows the test fixture's loopback target and test certificate. Ensure release app construction cannot select that policy.
- [ ] Update `tools/https_proxy_regression.py` to target an app/simulator acceptance endpoint instead of launching `carl`; preserve assertions for the guest's exact Rule 14 request and rendered response.

## Task 5: Add the core PCM output bridge

- [ ] Introduce a fixed-capacity single-producer/single-consumer PCM ring in `datarover_core.cpp`; allocate it before starting the worker and make writes from `sound_stream_sink_update` bounded, allocation-free, and nonblocking.
- [ ] Make `core_headless_osd` report sound enabled, return the correct sink/source identifiers and guest sample rate, consume volume updates where the core expects them, and push sink buffers into the ring. Keep source input silent and unopened because microphone capture is out of scope.
- [ ] Add ABI functions to read available mono/stereo signed PCM frames, clear buffered samples on restart/pause, and report playback initialization state; guard handle lifetime so audio is stopped before core destruction.
- [ ] Update the C ABI mirror and ABI drift checker in the same change. Preserve the legacy core creation entry point for CLI/test callers.

## Task 6: Add shared AVFAudio playback and lifecycle

- [ ] Implement `HostAudioOutput` with `AVAudioEngine` and `AVAudioSourceNode`, using the output node's hardware format and an explicit converter/resampler for the guest stream format.
- [ ] The source render closure must only pull PCM into preallocated audio buffers, write silence on underrun, and return immediately if stopped. Do not call SwiftUI, allocate, lock, or log from the real-time closure.
- [ ] Start after successful core creation; stop and clear on pause/background/restart/destruction; restart after foreground/resume. Route naturally to the host's selected speaker/headphone output.
- [ ] Show a playback failure status without failing emulator boot. Do not request microphone permission or add a microphone plist string.

## Task 7: Update generated project and developer documentation

- [ ] Run `xcodegen generate` and `python3 scripts/inject_mame_sources.py` only after reviewing the user's current Xcode project/scheme diff; retain the existing team/signing and scheme edits and check the final diff before staging.
- [ ] Update the developer docs with dependency build requirements, the guest network/proxy address and port, privacy behavior, failure messages, and the two-app acceptance invocation.
- [ ] Check `git diff --check`, the ABI copy with `python3 tools/check_core_abi.py`, and build both the macOS app and iOS simulator app. Do not add or run tests unless the user separately asks for test/verification work.
- [ ] Commit and push task-owned files to `magic-cap-emulator` `main` and task-owned core changes to `MattKevan/mame` `custom`; never stage pre-existing edits or push either upstream remote.
