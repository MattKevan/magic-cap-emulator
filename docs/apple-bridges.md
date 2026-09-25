# Apple app network and speaker bridges

The iOS/iPadOS and macOS apps share the bridge implementation in
`DataRoverShell`. Networking is off by default. Open the DataRover controls,
enable **Guest networking**, and relaunch the app. The guest gets MAME's
3Com EtherLink III card through rootless libslirp using the established
`10.0.2.15` guest, `10.0.2.2` host, and `10.0.2.3` DNS addresses. The
network is user-mode NAT; it does not expose a host interface.

For HTTPS in the Magic Cap browser, configure Rule 14 to use `10.0.2.2`, TCP
port `8765`, as described in [the TLS field report](oldvcr-tls.md). The app
listens on host loopback and makes validated TLS connections using the Apple
trust store. The proxy only accepts bounded GET, HEAD, and POST absolute-form
HTTPS requests. It rejects CONNECT, transfer-encoding, local/private literal
destinations, and DNS names that resolve to local or reserved address ranges.
Do not use it as a general purpose proxy. Proxy and
network failure does not prevent the emulator from starting.

Guest speaker output is enabled automatically and follows the current system
audio route and volume. Pausing or restarting the guest clears queued samples.
The bridge does not open the microphone.

## Building the Apple targets

Install Xcode command line tools, CMake, Meson, Ninja and pkg-config, then run
from the repository root:

```sh
apple/DataRover/scripts/build-network-deps.sh
```

The script downloads version-pinned libslirp, GLib and PCRE2 source archives,
checks their SHA-256 hashes, and builds static arm64 dependencies for iOS
device, iOS simulator, and macOS. Generated files live under
`build/apple-network-deps` and `build/apple-network-src`; neither directory is
committed. The dependency projects' license notices must accompany any
distributed app. Generate/inject the Xcode project as usual after building the
dependencies; both core targets and both apps link the same implementation.
