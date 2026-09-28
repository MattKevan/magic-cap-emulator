# Web Upgrade Proxy and Web Browser 4.0 Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Magic Cap's Web Browser 4.0 read modern HTTPS sites through a host proxy that the guest reaches transparently, and install the browser with one action in the Apple apps.

**Architecture:** A small patch to the pinned libslirp redirects guest TCP connections to port 80 onto host loopback. The core passes the proxy's port to libslirp through `datarover_create_options`. A new Swift target, `DataRoverWeb`, holds the proxy (request parsing, HTTPS fetch, page simplification, reader view, image transcoding, Windows-1252 output) and the package downloader. `DataRoverShell` starts the proxy before creating the core and adds the installer UI.

**Tech Stack:** C (libslirp 4.9.5, MAME OSD module), C++ (libdatarover), Swift 5.9 package (Network.framework, URLSession, ImageIO, CryptoKit, SwiftSoup 2.x), Swift Testing, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-09-28-web-upgrade-proxy-design.md`

## Global Constraints

- Platforms: iOS 26.0 and macOS 26.0, arm64 only (`apple/DataRoverKit/Package.swift`).
- Browser: Web Browser 4.0 (English) with MagicJavaScript only; no 3.5.1 download or patching in the app.
- Guest never speaks TLS; the proxy fetches `https://` first and retries `http://` once only when the TLS connection itself fails.
- Only guest TCP connections to port 80 are redirected; `0` disables the redirect.
- Proxy limits: 16 KB headers, 2 MB request body, 8 concurrent connections (503 beyond), 30 s per connection, 8 MB upstream response.
- Output HTML budget about 150 KB; images at most 480 px wide; JPEG quality 0.6; image cache 4 MB.
- Text served as Windows-1252. Japanese is out of scope.
- Start page host: `10.0.2.2`. Reader flag: query parameter `mcreader=1`.
- Search: `http://html.duckduckgo.com/html/` (fetched as HTTPS by the proxy).
- Packages (downloaded, never bundled):
  - `EtherLinkIII.pkg`, `https://joshcarter.com/magic_cap/packages/EtherLinkIII.pkg`, 65,624 bytes, `c0b23f24a91e7b03f4adf1a356dc4356f4091284a424119bbdd9d89f72279b34`
  - `WebBrowser40.mc2`, `https://joshcarter.com/magic_cap/packages/WebBrowser40.mc2`, 508,892 bytes, `b401b0f82beff0d945a4eb0361c8cf02aa16ec3fd79a3267edd46248c92bc706`
  - `MagicJavaScript.pkg`, `https://joshcarter.com/magic_cap/packages/MagicJavaScript.pkg`, 467,876 bytes, `beb0de0cdb51207534c280c88402ec11972dd7dfce11cd08514adc92c2f6f406`
- Settings keys: `datarover.network.enabled` (existing), `datarover.web.simplify` (new, default `true`).
- Repos: this repository (`main`) and `../mame` (branch `custom`). Commit and push each task to `origin` only. End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never commit ROMs, packages or anything from `../magic-cap-assets`.

## Review Focus

1. A `Host:` header with a port, mixed case or a trailing dot (`Example.COM:80`, `example.com.`) must fetch `https://example.com/…`, not fail. Test in Task 4.
2. An upstream page with no `Content-Type`, or with a non-UTF-8 charset (ISO-8859-1), must still be treated as HTML and decoded correctly. Test in Task 11.
3. Several `Set-Cookie` headers merged by URLSession into one comma-joined value, with `Expires=Wed, 21 Oct 2026 …` dates, must reach the guest as separate, intact cookies. Test in Task 5.
4. Pages that use `<base href>` or protocol-relative URLs (`//cdn.example/x.png`) must produce absolute `http://` links. Test in Task 8.
5. A `HEAD` request must return the headers without a body, including for error pages. Test in Task 11.

---

## File map

**libslirp and core**
- Create: `apple/DataRover/scripts/patches/libslirp-http-redirect.patch` — adds `slirp_set_http_redirect_port`.
- Modify: `apple/DataRover/scripts/build-network-deps.sh` — apply and verify the patch.
- Create: `apple/DataRover/scripts/tests/slirp_http_redirect_test.c`, `tools/test_slirp_http_redirect.sh`.
- Create: `../mame/src/osd/modules/netdev/slirp_redirect.h`.
- Modify: `../mame/src/osd/modules/netdev/slirp.cpp`, `../mame/src/libdatarover/datarover_core.h`, `../mame/src/libdatarover/datarover_core.cpp`.
- Create: `../mame/src/libdatarover/tests/network_options.cpp`, `tools/test_core_network_options.sh`.
- Modify: `apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h`, `apple/DataRoverKit/Sources/DataRoverShell/CoreHandle.swift`.

**Swift package** (`apple/DataRoverKit`)
- Modify: `Package.swift` — `DataRoverWeb` target, SwiftSoup, `DataRoverWebTests`.
- Create in `Sources/DataRoverWeb/`: `DestinationPolicy.swift`, `HTTPMessage.swift` (headers, request, response types), `RequestParser.swift`, `HeaderRewriter.swift`, `TextCoding.swift`, `ImageTranscoder.swift`, `HTMLCleaning.swift`, `PageSimplifier.swift`, `ReaderExtractor.swift`, `UpstreamFetcher.swift`, `StartPage.swift`, `ProxyPipeline.swift`, `WebProxy.swift`, `BrowserPackages.swift`.
- Create in `Tests/DataRoverWebTests/`: one test file per source file above, plus `StubURLProtocol.swift`.
- Modify: `Sources/DataRoverShell/HTTPSProxy.swift` (use `DestinationPolicy`), `EmulatorSession.swift`, `EmulatorControlsSheet.swift`.

**Docs**
- Modify: `docs/apple-bridges.md`.

---

### Task 1: libslirp port-80 redirect

**Files:**
- Create: `apple/DataRover/scripts/patches/libslirp-http-redirect.patch`
- Modify: `apple/DataRover/scripts/build-network-deps.sh` (after the three `tar -xf` lines)
- Create: `apple/DataRover/scripts/tests/slirp_http_redirect_test.c`
- Create: `tools/test_slirp_http_redirect.sh`

**Interfaces:**
- Produces: `void slirp_set_http_redirect_port(Slirp *slirp, uint16_t port);` and the feature macro `SLIRP_HAS_HTTP_REDIRECT` in `<slirp/libslirp.h>`.

- [ ] **Step 1: Write the failing test**

`apple/DataRover/scripts/tests/slirp_http_redirect_test.c`:

```c
// Proves the patched libslirp redirects guest TCP port 80 to a loopback port
// and leaves other destinations alone. Injects raw SYN frames; no guest needed.
#include <slirp/libslirp.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int64_t clock_ns(void *opaque) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque) { return (slirp_ssize_t)len; }
static void guest_error(const char *msg, void *opaque) { fprintf(stderr, "guest error: %s\n", msg); }
static int timer_token;
static void *timer_new(SlirpTimerCb cb, void *cb_opaque, void *opaque) { return &timer_token; }
static void timer_free(void *timer, void *opaque) {}
static void timer_mod(void *timer, int64_t expire, void *opaque) {}
static void register_poll_socket(slirp_os_socket socket, void *opaque) {}
static void unregister_poll_socket(slirp_os_socket socket, void *opaque) {}
static void notify(void *opaque) {}

static uint16_t checksum(const uint8_t *data, size_t len, uint32_t sum) {
    for (size_t i = 0; i + 1 < len; i += 2) sum += (uint32_t)(data[i] << 8 | data[i + 1]);
    if (len & 1) sum += (uint32_t)(data[len - 1] << 8);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

static void send_syn(Slirp *slirp, const char *dst, uint16_t dport, uint16_t sport) {
    uint8_t f[54] = {0};
    const uint8_t host_mac[6] = {0x52, 0x55, 0x0a, 0x00, 0x02, 0x02};
    const uint8_t guest_mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
    memcpy(f, host_mac, 6); memcpy(f + 6, guest_mac, 6); f[12] = 0x08; f[13] = 0x00;
    uint8_t *ip = f + 14, *tcp = f + 34;
    ip[0] = 0x45; ip[3] = 40; ip[6] = 0x40; ip[8] = 64; ip[9] = 6;
    inet_pton(AF_INET, "10.0.2.15", ip + 12); inet_pton(AF_INET, dst, ip + 16);
    uint16_t ipsum = checksum(ip, 20, 0); ip[10] = ipsum >> 8; ip[11] = ipsum & 0xff;
    tcp[0] = sport >> 8; tcp[1] = sport & 0xff; tcp[2] = dport >> 8; tcp[3] = dport & 0xff;
    tcp[7] = 1; tcp[12] = 5 << 4; tcp[13] = 0x02; tcp[14] = 0xff; tcp[15] = 0xff;
    uint8_t pseudo[12]; memcpy(pseudo, ip + 12, 8); pseudo[8] = 0; pseudo[9] = 6; pseudo[10] = 0; pseudo[11] = 20;
    uint32_t partial = 0;
    for (int i = 0; i < 12; i += 2) partial += (uint32_t)(pseudo[i] << 8 | pseudo[i + 1]);
    uint16_t tsum = checksum(tcp, 20, partial); tcp[16] = tsum >> 8; tcp[17] = tsum & 0xff;
    slirp_input(slirp, f, sizeof f);
}

static int listener(uint16_t *port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = 0 };
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 4)) { perror("listen"); exit(2); }
    socklen_t len = sizeof a; getsockname(fd, (struct sockaddr *)&a, &len);
    *port = ntohs(a.sin_port);
    return fd;
}

// 1 when a connection arrives within timeout_ms.
static int accepted(int fd, int timeout_ms) {
    struct pollfd p = { .fd = fd, .events = POLLIN };
    if (poll(&p, 1, timeout_ms) != 1) return 0;
    int c = accept(fd, NULL, NULL);
    if (c >= 0) close(c);
    return c >= 0;
}

static void require(int ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL %s\n", what); exit(1); }
    printf("ok   %s\n", what);
}

int main(void) {
    uint16_t redirect_port, other_port;
    int redirect = listener(&redirect_port), other = listener(&other_port);
    SlirpConfig cfg = {0};
    cfg.version = SLIRP_CONFIG_VERSION_MAX; cfg.in_enabled = true;
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork); inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost); inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    cfg.if_mtu = 1500; cfg.if_mru = 1500;
    SlirpCb cb = { .send_packet = send_packet, .guest_error = guest_error, .clock_get_ns = clock_ns,
                   .timer_new = timer_new, .timer_free = timer_free, .timer_mod = timer_mod,
                   .register_poll_socket = register_poll_socket,
                   .unregister_poll_socket = unregister_poll_socket, .notify = notify };
    Slirp *slirp = slirp_new(&cfg, &cb, NULL);
    require(slirp != NULL, "slirp_new");

    slirp_set_http_redirect_port(slirp, redirect_port);
    send_syn(slirp, "93.184.216.34", 80, 40001);
    require(accepted(redirect, 2000), "public :80 reaches the redirect port");
    send_syn(slirp, "10.0.2.2", 80, 40002);
    require(accepted(redirect, 2000), "10.0.2.2:80 reaches the redirect port");
    send_syn(slirp, "10.0.2.2", other_port, 40003);
    require(accepted(other, 2000) && !accepted(redirect, 200), "10.0.2.2:<other> is unchanged");

    slirp_set_http_redirect_port(slirp, 0);
    send_syn(slirp, "10.0.2.2", 80, 40004);
    require(!accepted(redirect, 300), "port 0 disables the redirect");

    slirp_cleanup(slirp);
    puts("PASS libslirp http redirect");
    return 0;
}
```

`tools/test_slirp_http_redirect.sh`:

```bash
#!/usr/bin/env bash
# Build and run the libslirp redirect test against the macOS dependency slice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/apple-network-deps/macosx"
SCRATCH="$(mktemp -d /tmp/datarover-slirp-redirect.XXXXXX)"
clang -std=c11 -I "$DEPS/include" "$ROOT/apple/DataRover/scripts/tests/slirp_http_redirect_test.c" \
  "$DEPS/lib/libslirp.a" "$DEPS/lib/libglib-2.0.a" "$DEPS/lib/libintl.a" "$DEPS/lib/libpcre2-8.a" \
  -framework Foundation -framework CoreMIDI -framework AudioToolbox -framework CoreAudio \
  -framework Carbon -framework Security -framework SystemConfiguration -liconv -lresolv \
  -o "$SCRATCH/slirp_http_redirect"
"$SCRATCH/slirp_http_redirect"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x tools/test_slirp_http_redirect.sh && tools/test_slirp_http_redirect.sh`
Expected: compile error, `implicit declaration of function 'slirp_set_http_redirect_port'` (or link error for the same symbol).

- [ ] **Step 3: Make the libslirp edits and generate the patch**

Work on a pristine copy so the patch is exact:

```bash
cd build/apple-network-src
rm -rf libslirp-pristine libslirp-edit
mkdir libslirp-pristine && tar -xf libslirp-4.9.5.tar.gz -C libslirp-pristine --strip-components=1
cp -R libslirp-pristine libslirp-edit
```

In `libslirp-edit/src/libslirp.h`, directly after the `slirp_remove_guestfwd` declaration, add:

```c
/* Redirect guest TCP connections to port 80, for any destination, to host
 * 127.0.0.1:port. 0 disables. Other ports and protocols are unchanged. */
#define SLIRP_HAS_HTTP_REDIRECT 1
SLIRP_EXPORT
void slirp_set_http_redirect_port(Slirp *slirp, uint16_t port);
```

In `libslirp-edit/src/slirp.h`, in `struct Slirp`, directly after `bool disable_host_loopback;`, add:

```c
    uint16_t http_redirect_port;
```

In `libslirp-edit/src/slirp.c`, at the end of the file, add:

```c
void slirp_set_http_redirect_port(Slirp *slirp, uint16_t port)
{
    slirp->http_redirect_port = port;
}
```

In `libslirp-edit/src/tcp_subr.c`, in `tcp_fconnect`, replace:

```c
        if (sotranslate_out(so, &addr) < 0) {
            return -1;
        }
```

with:

```c
        if (sotranslate_out(so, &addr) < 0) {
            return -1;
        }
        if (so->slirp->http_redirect_port && addr.ss_family == AF_INET &&
            ((struct sockaddr_in *)&addr)->sin_port == htons(80)) {
            ((struct sockaddr_in *)&addr)->sin_addr = loopback_addr;
            ((struct sockaddr_in *)&addr)->sin_port = htons(so->slirp->http_redirect_port);
        }
```

Generate the patch and clean up:

```bash
mkdir -p ../../apple/DataRover/scripts/patches
diff -ru libslirp-pristine libslirp-edit \
  | sed -e 's#^--- libslirp-pristine/#--- a/#' -e 's#^+++ libslirp-edit/#+++ b/#' \
  > ../../apple/DataRover/scripts/patches/libslirp-http-redirect.patch || true
rm -rf libslirp-pristine libslirp-edit
cd ../..
```

(`diff` exits 1 when files differ; `|| true` keeps the shell going.) Confirm the patch touches exactly four files: `grep '^+++' apple/DataRover/scripts/patches/libslirp-http-redirect.patch`.

- [ ] **Step 4: Apply the patch in the build script**

In `apple/DataRover/scripts/build-network-deps.sh`, directly after the `tar -xf "$SRC/libslirp-$SLIRP_VERSION.tar.gz" …` line, add:

```bash
# Local change: transparent port-80 redirect for the web upgrade proxy.
patch -d "$SRC/libslirp" -p1 --forward --batch \
  < "$ROOT/apple/DataRover/scripts/patches/libslirp-http-redirect.patch"
grep -q 'slirp_set_http_redirect_port' "$SRC/libslirp/src/libslirp.h" || {
  echo "libslirp redirect patch did not apply" >&2; exit 1;
}
```

`tar -x` re-extracts pristine sources on every run, so the patch always applies to a clean tree.

- [ ] **Step 5: Rebuild the dependencies and run the test**

Run: `apple/DataRover/scripts/build-network-deps.sh` (builds three slices; expect tens of minutes).
Then: `tools/test_slirp_http_redirect.sh`
Expected: four `ok` lines and `PASS libslirp http redirect`.

- [ ] **Step 6: Commit**

```bash
git add apple/DataRover/scripts/patches/libslirp-http-redirect.patch apple/DataRover/scripts/build-network-deps.sh \
  apple/DataRover/scripts/tests/slirp_http_redirect_test.c tools/test_slirp_http_redirect.sh
git commit -m "Add libslirp port-80 redirect for the web upgrade proxy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 2: Core option for the redirect port

**Files:**
- Create: `../mame/src/osd/modules/netdev/slirp_redirect.h`
- Modify: `../mame/src/osd/modules/netdev/slirp.cpp` (includes; constructor after `slirp_new`)
- Modify: `../mame/src/libdatarover/datarover_core.h:13-18`
- Modify: `../mame/src/libdatarover/datarover_core.cpp` (`core_headless_osd` constructor and `init`, `datarover_create_with_options` near line 825, `datarover_create` near line 1251)
- Create: `../mame/src/libdatarover/tests/network_options.cpp`, `tools/test_core_network_options.sh`
- Modify: `apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h:22-26`
- Modify: `apple/DataRoverKit/Sources/DataRoverShell/CoreHandle.swift` (`coreCreate`)

**Interfaces:**
- Consumes: `slirp_set_http_redirect_port`, `SLIRP_HAS_HTTP_REDIRECT` (Task 1).
- Produces:
  - C: `datarover_create_options` gains `int32_t http_redirect_port;` as its last field.
  - C++: `namespace osd { void set_slirp_http_redirect_port(uint16_t); uint16_t slirp_http_redirect_port(); }`
  - Swift: `coreCreate(nvram:cfg:rom:networkEnabled:httpRedirectPort:) -> UnsafeMutableRawPointer?` with `httpRedirectPort: UInt16 = 0`.

- [ ] **Step 1: Write the failing test**

`../mame/src/libdatarover/tests/network_options.cpp`:

```cpp
// Checks option-struct compatibility and redirect-port plumbing into slirp.
#include "datarover_core.h"
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <thread>
namespace osd { uint16_t slirp_http_redirect_port(); }
namespace fs = std::filesystem;
using namespace std::chrono_literals;

static void require(bool ok, const char *what) {
	if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); std::fflush(nullptr); std::_Exit(1); }
	std::printf("ok   %s\n", what);
}
static bool network_ready(void *core) {
	for (int i = 0; i < 250; ++i) {
		if (datarover_network_status(core) == 1) return true;
		std::this_thread::sleep_for(20ms);
	}
	return false;
}

int main(int argc, char **argv) {
	if (argc != 3) return 2;
	fs::path base(argv[2]);
	fs::create_directories(base / "cfg"); fs::create_directories(base / "nvram");

	datarover_create_options current{};
	current.struct_size = sizeof current;
	current.network_enabled = 1;
	current.http_redirect_port = 54321;
	void *core = datarover_create_with_options((base / "nvram").c_str(), (base / "cfg").c_str(), argv[1], &current);
	require(core, "boot with the current options");
	require(network_ready(core), "network ready with the current options");
	require(osd::slirp_http_redirect_port() == 54321, "redirect port reaches slirp");
	datarover_destroy(core);

	// A caller built before http_redirect_port existed passes the old size.
	datarover_create_options legacy{};
	legacy.struct_size = offsetof(datarover_create_options, http_redirect_port);
	legacy.network_enabled = 1;
	legacy.http_redirect_port = 999; // must be ignored: outside the old size
	core = datarover_create_with_options((base / "nvram").c_str(), (base / "cfg").c_str(), argv[1], &legacy);
	require(core, "boot with legacy-sized options");
	require(network_ready(core), "legacy-sized options still enable networking");
	require(osd::slirp_http_redirect_port() == 0, "legacy-sized options leave the redirect off");
	datarover_destroy(core);
	std::puts("PASS network options");
}
```

`tools/test_core_network_options.sh`:

```bash
#!/usr/bin/env bash
# Exercise the built macOS core library's create options with isolated state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAME_DIR="${MAME_DIR:-$ROOT/../mame}"
: "${CORE_LIBRARY:?Set CORE_LIBRARY to the built libDataRoverCoreMac.a}"
: "${ROM_PATH:?Set ROM_PATH to your Magic Cap ROM image}"
SCRATCH="$(mktemp -d /tmp/datarover-network-options.XXXXXX)"
DEPS="$ROOT/build/apple-network-deps/macosx/lib"
clang++ -std=c++20 -I "$MAME_DIR/src/libdatarover" \
  "$MAME_DIR/src/libdatarover/tests/network_options.cpp" "$CORE_LIBRARY" \
  "$DEPS/libslirp.a" "$DEPS/libglib-2.0.a" "$DEPS/libintl.a" "$DEPS/libpcre2-8.a" \
  -framework Foundation -framework CoreMIDI -framework AudioToolbox \
  -framework CoreAudio -framework Carbon -framework Security \
  -framework SystemConfiguration -liconv -lresolv -o "$SCRATCH/network_options"
python3 - "$SCRATCH/network_options" "$ROM_PATH" "$SCRATCH/state" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=90).returncode)
except subprocess.TimeoutExpired:
    sys.exit("FAIL network options exceeded 90 seconds")
PY
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x tools/test_core_network_options.sh && CORE_LIBRARY=… ROM_PATH=… tools/test_core_network_options.sh`
(`CORE_LIBRARY` is `~/Library/Developer/Xcode/DerivedData/DataRover-*/Build/Products/Debug/libDataRoverCoreMac.a`; `ROM_PATH` is `../magic-cap-assets/roms/datarover840/magiccap-usa.image`.)
Expected: compile error, `no member named 'http_redirect_port' in 'datarover_create_options'`.

- [ ] **Step 3: Add the option and plumbing**

`../mame/src/osd/modules/netdev/slirp_redirect.h`:

```cpp
// Process-wide port-80 redirect for the libslirp provider. Set before the
// network device opens; 0 disables. Only one emulated machine runs per process.
#pragma once
#include <cstdint>

namespace osd {
void set_slirp_http_redirect_port(uint16_t port);
uint16_t slirp_http_redirect_port();
} // namespace osd
```

In `../mame/src/osd/modules/netdev/slirp.cpp`, add `#include "slirp_redirect.h"` and `#include <atomic>` with the other includes (inside the `OSD_NET_USE_SLIRP` guard). Directly inside `namespace osd {` (before the anonymous namespace), add:

```cpp
namespace {
std::atomic<uint16_t> s_http_redirect_port{ 0 };
} // anonymous namespace

void set_slirp_http_redirect_port(uint16_t port) { s_http_redirect_port.store(port); }
uint16_t slirp_http_redirect_port() { return s_http_redirect_port.load(); }
```

In the `netdev_slirp` constructor, directly after `m_slirp = slirp_new(&config, &m_callbacks, this);`, add:

```cpp
#if defined(SLIRP_HAS_HTTP_REDIRECT)
	if (m_slirp)
		slirp_set_http_redirect_port(m_slirp, slirp_http_redirect_port());
#endif
```

(System libslirp builds without the patch compile unchanged.)

In `../mame/src/libdatarover/datarover_core.h`, replace the struct with:

```c
typedef struct datarover_create_options
{
	uint32_t struct_size;
	int32_t network_enabled;
	int32_t audio_output_enabled;
	// Host loopback port for guest TCP port 80 (the web upgrade proxy);
	// 0 disables. Needs network_enabled. Appended: older callers pass a
	// smaller struct_size and get 0.
	int32_t http_redirect_port;
} datarover_create_options;
```

In `../mame/src/libdatarover/datarover_core.cpp`:

- Add `#include "osd/modules/netdev/slirp_redirect.h"` inside an `#if defined(OSD_NET_USE_SLIRP)` block beside the existing `NETDEV_SLIRP` declaration, and `#include <cstddef>` with the standard includes.
- Change the `core_headless_osd` constructor to take and store the port:

```cpp
	core_headless_osd(osd_options &options, bool network_enabled, bool audio_enabled, uint16_t http_redirect_port)
		: m_options(options), m_network_enabled(network_enabled), m_audio_enabled(audio_enabled)
		, m_http_redirect_port(http_redirect_port) { }
```

and add `uint16_t m_http_redirect_port;` beside `bool m_network_enabled;`.
- In `init`, inside `#if defined(OSD_NET_USE_SLIRP)` and before `m_modules.register_module(NETDEV_SLIRP);`, add `osd::set_slirp_http_redirect_port(m_http_redirect_port);`.
- Replace the two option reads in `datarover_create_with_options` with per-field checks:

```cpp
	auto const provides = [create_options](std::size_t field_end) {
		return create_options && create_options->struct_size >= field_end;
	};
	const bool network_enabled = provides(offsetof(datarover_create_options, network_enabled) + sizeof(int32_t))
			&& create_options->network_enabled;
	const bool audio_enabled = provides(offsetof(datarover_create_options, audio_output_enabled) + sizeof(int32_t))
			&& create_options->audio_output_enabled;
	const int32_t requested_redirect = provides(offsetof(datarover_create_options, http_redirect_port) + sizeof(int32_t))
			? create_options->http_redirect_port : 0;
	const uint16_t http_redirect_port = network_enabled && requested_redirect > 0 && requested_redirect <= 65535
			? uint16_t(requested_redirect) : 0;
```

- Pass `http_redirect_port` as the new fourth argument where `core_headless_osd` is constructed (near line 893).
- In `datarover_create`, change the defaults to `const datarover_create_options defaults{ sizeof(datarover_create_options), 0, 0, 0 };`.

Mirror the struct in `apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h` (same field order and types):

```c
typedef struct datarover_create_options {
    uint32_t struct_size;
    int32_t network_enabled;
    int32_t audio_output_enabled;
    int32_t http_redirect_port;
} datarover_create_options;
```

In `apple/DataRoverKit/Sources/DataRoverShell/CoreHandle.swift`, replace `coreCreate` with:

```swift
/// Create a core handle. Returns nil when the fork returns NULL
/// (boot failure). Caller owns the handle; destroy with `coreDestroy`.
/// `httpRedirectPort` sends guest TCP port 80 to that loopback port; 0 is off.
public func coreCreate(nvram: String, cfg: String, rom: String, networkEnabled: Bool,
                       httpRedirectPort: UInt16 = 0) -> UnsafeMutableRawPointer? {
    var options = datarover_create_options(
        struct_size: UInt32(MemoryLayout<datarover_create_options>.size),
        network_enabled: networkEnabled ? 1 : 0,
        audio_output_enabled: 1,
        http_redirect_port: Int32(httpRedirectPort)
    )
    return withUnsafePointer(to: &options) { optionsPointer in
        datarover_create_with_options(nvram, cfg, rom, optionsPointer)
    }
}
```

- [ ] **Step 4: Rebuild the macOS core and run the tests**

Run: `tools/build_mac_swift_app.sh` (rebuilds `libDataRoverCoreMac.a` and the app).
Then: `CORE_LIBRARY=… ROM_PATH=… tools/test_core_network_options.sh`
Expected: five `ok` lines and `PASS network options`.
Also run: `python3 tools/check_core_abi.py` (expected: `ABI copy matches the fork header`) and the existing `tools/test_core_checkpoint.sh` (expected: `PASS checkpoint restore, guest touch response and prompt restart`).

- [ ] **Step 5: Commit both repositories**

```bash
git -C ../mame add src/osd/modules/netdev/slirp_redirect.h src/osd/modules/netdev/slirp.cpp \
  src/libdatarover/datarover_core.h src/libdatarover/datarover_core.cpp src/libdatarover/tests/network_options.cpp
git -C ../mame commit -m "datarover: pass a port-80 redirect to libslirp

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C ../mame push origin custom
git add apple/DataRoverKit/Sources/CDataRoverABI/include/CoreBridge.h \
  apple/DataRoverKit/Sources/DataRoverShell/CoreHandle.swift tools/test_core_network_options.sh
git commit -m "Pass the web proxy port to the core

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 3: `DataRoverWeb` target and shared destination policy

**Files:**
- Modify: `apple/DataRoverKit/Package.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/DestinationPolicy.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/DestinationPolicyTests.swift`
- Modify: `apple/DataRoverKit/Sources/DataRoverShell/HTTPSProxy.swift` (remove `isForbiddenHost` and `resolvesOnlyPublicAddresses`; call `DestinationPolicy`)

**Interfaces:**
- Produces: `public enum DestinationPolicy { static func isForbiddenHost(_ host: String) -> Bool; static func resolvesOnlyPublicAddresses(_ host: String) -> Bool; static func allows(_ host: String) -> Bool }` where `allows` is `!isForbiddenHost(host) && resolvesOnlyPublicAddresses(host)`.

- [ ] **Step 1: Add the target and write the failing test**

Replace `apple/DataRoverKit/Package.swift` with:

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
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "CDataRoverABI"),
        .target(name: "DataRoverKit"),
        // Host web proxy and package downloads. No core dependency, so its
        // tests link without the emulator library.
        .target(name: "DataRoverWeb", dependencies: ["SwiftSoup"]),
        .target(name: "DataRoverShell", dependencies: ["DataRoverKit", "DataRoverWeb", "CDataRoverABI"],
                resources: [.process("Resources")]),
        .testTarget(name: "DataRoverKitTests", dependencies: ["DataRoverKit"]),
        .testTarget(name: "DataRoverWebTests", dependencies: ["DataRoverWeb"]),
    ]
)
```

`apple/DataRoverKit/Tests/DataRoverWebTests/DestinationPolicyTests.swift`:

```swift
import Testing
@testable import DataRoverWeb

@Suite struct DestinationPolicyTests {
    @Test func rejectsLocalNames() {
        for host in ["localhost", "a.localhost", "printer.local", "[::1]", "fe80::1"] {
            #expect(DestinationPolicy.isForbiddenHost(host), "\(host)")
        }
    }

    @Test func rejectsPrivateAndReservedIPv4Literals() {
        for host in ["0.0.0.0", "10.0.2.2", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255",
                     "192.168.1.1", "100.64.0.1", "192.0.0.8", "198.18.0.1", "224.0.0.1", "240.0.0.1"] {
            #expect(DestinationPolicy.isForbiddenHost(host), "\(host)")
        }
    }

    @Test func rejectsNumericEncodingsBeforeDNS() {
        for host in ["2130706433", "0x7f000001", "017700000001", "93.184.216.34"] {
            #expect(!DestinationPolicy.resolvesOnlyPublicAddresses(host), "\(host)")
        }
    }

    @Test func allowsOrdinaryPublicNamesLexically() {
        #expect(!DestinationPolicy.isForbiddenHost("en.wikipedia.org"))
        #expect(!DestinationPolicy.isForbiddenHost("172.32.0.1"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter DataRoverWebTests`
Expected: FAIL to compile, `cannot find 'DestinationPolicy' in scope` (after SwiftSoup resolves).

- [ ] **Step 3: Move the policy**

Create `apple/DataRoverKit/Sources/DataRoverWeb/DestinationPolicy.swift`:

```swift
import Darwin
import Foundation

/// Which upstream hosts the host proxies may contact: public Internet only.
public enum DestinationPolicy {
    public static func allows(_ host: String) -> Bool {
        !isForbiddenHost(host) && resolvesOnlyPublicAddresses(host)
    }
}
```

Then move `isForbiddenHost(_:)` and `resolvesOnlyPublicAddresses(_:)` from `HTTPSProxy.swift` into an `extension DestinationPolicy` in the same file, unchanged except for changing `private static func` to `public static func`. In `HTTPSProxy.swift`, add `import DataRoverWeb` and replace `!isForbiddenHost(host), resolvesOnlyPublicAddresses(host)` in `parse` with `DestinationPolicy.allows(host)`; delete the two moved functions from `HTTPSProxy`.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit`
Expected: all DataRoverKitTests and DestinationPolicyTests pass. Commit `Package.resolved` if SwiftPM created one.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Package.swift apple/DataRoverKit/Package.resolved \
  apple/DataRoverKit/Sources/DataRoverWeb apple/DataRoverKit/Tests/DataRoverWebTests \
  apple/DataRoverKit/Sources/DataRoverShell/HTTPSProxy.swift
git commit -m "Add DataRoverWeb target with the shared destination policy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 4: HTTP messages and request parsing

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/HTTPMessage.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/RequestParser.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/RequestParserTests.swift`

**Interfaces:**
- Produces:

```swift
public struct HTTPHeader: Equatable, Sendable { public var name: String; public var value: String }
public struct ProxyRequest: Equatable, Sendable {
    public var method: String        // "GET", "HEAD" or "POST"
    public var host: String          // lowercased, no port 80, no trailing dot; may include ":port" for others
    public var target: String        // path and query, starts with "/", mcreader removed
    public var headers: [HTTPHeader] // hop-by-hop headers removed
    public var body: Data
    public var reader: Bool          // mcreader=1 was present
}
public struct ProxyResponse: Equatable, Sendable {
    public var status: Int; public var reason: String; public var headers: [HTTPHeader]; public var body: Data
    public func serialized(includeBody: Bool) -> Data
}
public enum RequestParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 2 * 1024 * 1024
    public enum Outcome: Equatable { case complete(ProxyRequest), incomplete, invalid(status: Int) }
    public static func parse(_ data: Data) -> Outcome
}
```

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/RequestParserTests.swift`:

```swift
import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct RequestParserTests {
    private func parse(_ text: String) -> RequestParser.Outcome { RequestParser.parse(Data(text.utf8)) }

    private func request(_ text: String) throws -> ProxyRequest {
        guard case .complete(let request) = parse(text) else { throw CancellationError() }
        return request
    }

    @Test func parsesOriginForm() throws {
        let r = try request("GET /wiki/Magic_Cap?x=1 HTTP/1.0\r\nHost: en.wikipedia.org\r\nUser-Agent: MCWB\r\n\r\n")
        #expect(r.method == "GET")
        #expect(r.host == "en.wikipedia.org")
        #expect(r.target == "/wiki/Magic_Cap?x=1")
        #expect(r.headers == [HTTPHeader(name: "User-Agent", value: "MCWB")])
        #expect(!r.reader)
    }

    @Test func parsesAbsoluteForm() throws {
        let r = try request("GET http://example.com/a HTTP/1.0\r\n\r\n")
        #expect(r.host == "example.com")
        #expect(r.target == "/a")
    }

    @Test func normalizesHostPortCaseAndTrailingDot() throws {
        #expect(try request("GET / HTTP/1.0\r\nHost: Example.COM:80\r\n\r\n").host == "example.com")
        #expect(try request("GET / HTTP/1.0\r\nHost: example.com.\r\n\r\n").host == "example.com")
        #expect(try request("GET / HTTP/1.0\r\nHost: example.com:8080\r\n\r\n").host == "example.com:8080")
    }

    @Test func stripsReaderFlag() throws {
        let only = try request("GET /a?mcreader=1 HTTP/1.0\r\nHost: e.com\r\n\r\n")
        #expect(only.reader && only.target == "/a")
        let mixed = try request("GET /a?x=1&mcreader=1&y=2 HTTP/1.0\r\nHost: e.com\r\n\r\n")
        #expect(mixed.reader && mixed.target == "/a?x=1&y=2")
    }

    @Test func dropsHopByHopHeaders() throws {
        let r = try request("GET / HTTP/1.0\r\nHost: e.com\r\nConnection: keep-alive\r\nProxy-Connection: x\r\nKeep-Alive: 1\r\nAccept-Encoding: gzip\r\nCookie: a=b\r\n\r\n")
        #expect(r.headers == [HTTPHeader(name: "Cookie", value: "a=b")])
    }

    @Test func waitsForTheBody() throws {
        #expect(parse("POST /f HTTP/1.0\r\nHost: e.com\r\nContent-Length: 5\r\n\r\nab") == .incomplete)
        let r = try request("POST /f HTTP/1.0\r\nHost: e.com\r\nContent-Length: 5\r\n\r\nabcde")
        #expect(r.body == Data("abcde".utf8))
        #expect(r.headers.contains(HTTPHeader(name: "Content-Length", value: "5")))
    }

    @Test func rejectsWhatItCannotServe() {
        #expect(parse("PUT / HTTP/1.0\r\nHost: e.com\r\n\r\n") == .invalid(status: 405))
        #expect(parse("GET / HTTP/1.0\r\n\r\n") == .invalid(status: 400))
        #expect(parse("GET / HTTP/1.0\r\nHost: e.com\r\nTransfer-Encoding: chunked\r\n\r\n") == .invalid(status: 400))
        #expect(parse("GET / HTTP/1.0\r\nHost: e.com\r\nContent-Length: 9999999\r\n\r\n") == .invalid(status: 413))
        let huge = "GET / HTTP/1.0\r\nHost: e.com\r\nX: " + String(repeating: "a", count: 17_000)
        #expect(parse(huge) == .invalid(status: 431))
    }

    @Test func serializesResponses() {
        let response = ProxyResponse(status: 200, reason: "OK",
                                     headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                                     body: Data("hi".utf8))
        #expect(String(decoding: response.serialized(includeBody: true), as: UTF8.self)
                == "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nhi")
        #expect(String(decoding: response.serialized(includeBody: false), as: UTF8.self)
                == "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter RequestParserTests`
Expected: FAIL to compile, `cannot find 'RequestParser' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/HTTPMessage.swift`:

```swift
import Foundation

public struct HTTPHeader: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// One guest request, normalized for the upstream fetch.
public struct ProxyRequest: Equatable, Sendable {
    public var method: String
    public var host: String
    public var target: String
    public var headers: [HTTPHeader]
    public var body: Data
    public var reader: Bool

    public init(method: String, host: String, target: String, headers: [HTTPHeader] = [],
                body: Data = Data(), reader: Bool = false) {
        self.method = method; self.host = host; self.target = target
        self.headers = headers; self.body = body; self.reader = reader
    }
}

/// An HTTP/1.0 response for the guest browser.
public struct ProxyResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [HTTPHeader]
    public var body: Data

    public init(status: Int, reason: String, headers: [HTTPHeader], body: Data) {
        self.status = status; self.reason = reason; self.headers = headers; self.body = body
    }

    public func serialized(includeBody: Bool) -> Data {
        var head = "HTTP/1.0 \(status) \(reason)\r\n"
        for header in headers { head += "\(header.name): \(header.value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }
}
```

`apple/DataRoverKit/Sources/DataRoverWeb/RequestParser.swift`:

```swift
import Foundation

/// Parses one HTTP/1.0 request from the guest browser.
public enum RequestParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 2 * 1024 * 1024

    public enum Outcome: Equatable {
        case complete(ProxyRequest)
        case incomplete
        case invalid(status: Int)
    }

    private static let hopByHop: Set<String> = [
        "host", "connection", "proxy-connection", "keep-alive", "proxy-authorization",
        "te", "trailer", "upgrade", "accept-encoding",
    ]

    public static func parse(_ data: Data) -> Outcome {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(status: 431) }
        guard let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .isoLatin1) else {
            return .invalid(status: 400)
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        let method = parts[0].uppercased()
        guard ["GET", "HEAD", "POST"].contains(method) else { return .invalid(status: 405) }

        var headers: [HTTPHeader] = []
        var hostHeader: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(status: 400) }
            let lower = name.lowercased()
            if lower == "transfer-encoding" { return .invalid(status: 400) }
            if lower == "host" { hostHeader = value; continue }
            if lower == "content-length" {
                guard let length = Int(value), length >= 0 else { return .invalid(status: 400) }
                guard length <= maxBodyBytes else { return .invalid(status: 413) }
                contentLength = length
            }
            if hopByHop.contains(lower) || lower.hasPrefix("proxy-") { continue }
            headers.append(HTTPHeader(name: name, value: value))
        }

        var target = parts[1]
        var host = hostHeader
        if let absolute = URL(string: target), let scheme = absolute.scheme?.lowercased(),
           scheme == "http", let authority = absolute.host {
            host = absolute.port.map { "\(authority):\($0)" } ?? authority
            let path = absolute.path.isEmpty ? "/" : absolute.path
            target = path + (absolute.query.map { "?\($0)" } ?? "")
        }
        guard target.hasPrefix("/"), let rawHost = host, let normalized = normalizeHost(rawHost) else {
            return .invalid(status: 400)
        }

        let bodyStart = end.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        if available < contentLength { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let (cleanTarget, reader) = removeReaderFlag(target)
        return .complete(ProxyRequest(method: method, host: normalized, target: cleanTarget,
                                      headers: headers, body: body, reader: reader))
    }

    static func normalizeHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        var port: String?
        if let colon = host.lastIndex(of: ":"), !host.contains("]") {
            port = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            return nil
        }
        guard let port, port != "80" else { return host }
        guard let number = Int(port), (1...65_535).contains(number) else { return nil }
        return "\(host):\(number)"
    }

    static func removeReaderFlag(_ target: String) -> (String, Bool) {
        guard let question = target.firstIndex(of: "?") else { return (target, false) }
        let path = String(target[..<question])
        let items = target[target.index(after: question)...].split(separator: "&", omittingEmptySubsequences: false)
        let kept = items.filter { $0 != "mcreader=1" }
        let reader = kept.count != items.count
        return (kept.isEmpty ? path : path + "?" + kept.joined(separator: "&"), reader)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter RequestParserTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/HTTPMessage.swift apple/DataRoverKit/Sources/DataRoverWeb/RequestParser.swift \
  apple/DataRoverKit/Tests/DataRoverWebTests/RequestParserTests.swift
git commit -m "Parse guest browser requests for the web proxy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 5: Response header rewriting

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/HeaderRewriter.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/HeaderRewriterTests.swift`

**Interfaces:**
- Consumes: `HTTPHeader` (Task 4).
- Produces: `public enum HeaderRewriter { static func downgrade(_ text: String) -> String; static func rewrite(_ headers: [HTTPHeader]) -> [HTTPHeader]; static func splitSetCookie(_ value: String) -> [String] }`. `rewrite` removes framing headers (`Content-Length`, `Content-Type` is kept); callers add `Content-Type`, `Content-Length` and `Connection` themselves.

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/HeaderRewriterTests.swift`:

```swift
import Testing
@testable import DataRoverWeb

@Suite struct HeaderRewriterTests {
    @Test func downgradesSchemes() {
        #expect(HeaderRewriter.downgrade("https://a.org/x https://b.org") == "http://a.org/x http://b.org")
        #expect(HeaderRewriter.downgrade("HTTPS://A.org") == "http://A.org")
    }

    @Test func rewritesRedirectsAndDropsSecurityHeaders() {
        let out = HeaderRewriter.rewrite([
            HTTPHeader(name: "Location", value: "https://e.com/next"),
            HTTPHeader(name: "Content-Location", value: "https://e.com/c"),
            HTTPHeader(name: "Strict-Transport-Security", value: "max-age=1"),
            HTTPHeader(name: "Content-Security-Policy", value: "default-src 'self'"),
            HTTPHeader(name: "Content-Security-Policy-Report-Only", value: "x"),
            HTTPHeader(name: "Content-Encoding", value: "gzip"),
            HTTPHeader(name: "Transfer-Encoding", value: "chunked"),
            HTTPHeader(name: "Content-Length", value: "10"),
            HTTPHeader(name: "Connection", value: "keep-alive"),
            HTTPHeader(name: "Alt-Svc", value: "h3=\":443\""),
            HTTPHeader(name: "Content-Type", value: "text/html"),
        ])
        #expect(out == [
            HTTPHeader(name: "Location", value: "http://e.com/next"),
            HTTPHeader(name: "Content-Location", value: "http://e.com/c"),
            HTTPHeader(name: "Content-Type", value: "text/html"),
        ])
    }

    @Test func stripsSecureAndSameSiteFromCookies() {
        let out = HeaderRewriter.rewrite([HTTPHeader(name: "Set-Cookie", value: "id=1; Path=/; Secure; HttpOnly; SameSite=Lax")])
        #expect(out == [HTTPHeader(name: "Set-Cookie", value: "id=1; Path=/; HttpOnly")])
    }

    @Test func splitsCookiesMergedByURLSession() {
        let merged = "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure, b=2; Path=/, c=3"
        #expect(HeaderRewriter.splitSetCookie(merged)
                == ["a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Secure", "b=2; Path=/", "c=3"])
        let out = HeaderRewriter.rewrite([HTTPHeader(name: "Set-Cookie", value: merged)])
        #expect(out.map(\.value) == ["a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT", "b=2; Path=/", "c=3"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter HeaderRewriterTests`
Expected: FAIL to compile, `cannot find 'HeaderRewriter' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/HeaderRewriter.swift`:

```swift
import Foundation

/// Adapts upstream HTTPS response headers for a guest that only sees HTTP.
public enum HeaderRewriter {
    private static let dropped: Set<String> = [
        "strict-transport-security", "content-security-policy", "content-security-policy-report-only",
        "content-encoding", "transfer-encoding", "content-length", "connection", "keep-alive", "alt-svc",
    ]

    public static func downgrade(_ text: String) -> String {
        text.replacingOccurrences(of: "https://", with: "http://", options: .caseInsensitive)
    }

    public static func rewrite(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        var out: [HTTPHeader] = []
        for header in headers {
            let lower = header.name.lowercased()
            if dropped.contains(lower) { continue }
            switch lower {
            case "location", "content-location":
                out.append(HTTPHeader(name: header.name, value: downgrade(header.value)))
            case "set-cookie":
                for cookie in splitSetCookie(header.value) {
                    out.append(HTTPHeader(name: header.name, value: stripCookieSecurity(cookie)))
                }
            default:
                out.append(header)
            }
        }
        return out
    }

    /// URLSession joins repeated Set-Cookie headers with ", ". Split only at a
    /// comma followed by a new `name=`, so Expires dates stay intact.
    public static func splitSetCookie(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #",\s*(?=[^;,=\s]+=)"#)
        let range = NSRange(value.startIndex..., in: value)
        var pieces: [String] = []
        var start = value.startIndex
        for match in pattern.matches(in: value, range: range) {
            guard let r = Range(match.range, in: value) else { continue }
            let piece = value[start..<r.lowerBound]
            // A comma directly inside an Expires date is followed by a day
            // number, never `name=`, so this split is between cookies.
            pieces.append(piece.trimmingCharacters(in: .whitespaces))
            start = r.upperBound
        }
        pieces.append(value[start...].trimmingCharacters(in: .whitespaces))
        return pieces.filter { !$0.isEmpty }
    }

    private static func stripCookieSecurity(_ cookie: String) -> String {
        cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { attribute in
                let name = attribute.split(separator: "=").first.map { $0.lowercased() } ?? ""
                return name != "secure" && name != "samesite"
            }
            .joined(separator: "; ")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter HeaderRewriterTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/HeaderRewriter.swift apple/DataRoverKit/Tests/DataRoverWebTests/HeaderRewriterTests.swift
git commit -m "Rewrite upstream response headers for the guest browser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 6: Text decoding and Windows-1252 output

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/TextCoding.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/TextCodingTests.swift`

**Interfaces:**
- Produces: `public enum TextCoding { static func decode(_ data: Data, contentType: String?) -> String; static func windows1252(_ text: String, html: Bool) -> Data; static let htmlContentType = "text/html; charset=windows-1252"; static let textContentType = "text/plain; charset=windows-1252" }`. With `html: true`, characters outside Windows-1252 become `&#N;`; with `html: false` they become `?`.

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/TextCodingTests.swift`:

```swift
import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct TextCodingTests {
    @Test func encodesLatin1AndWindowsPunctuationDirectly() {
        #expect(TextCoding.windows1252("café", html: true) == Data([0x63, 0x61, 0x66, 0xE9]))
        #expect(TextCoding.windows1252("€—“”’…", html: true) == Data([0x80, 0x97, 0x93, 0x94, 0x92, 0x85]))
    }

    @Test func escapesEverythingElse() {
        #expect(String(decoding: TextCoding.windows1252("a→b😀", html: true), as: UTF8.self) == "a&#8594;b&#128512;")
        #expect(String(decoding: TextCoding.windows1252("a→b", html: false), as: UTF8.self) == "a?b")
    }

    @Test func decodesUsingTheHeaderCharset() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(TextCoding.decode(latin1, contentType: "text/html; charset=ISO-8859-1") == "café")
        #expect(TextCoding.decode(Data("café".utf8), contentType: "text/html; charset=utf-8") == "café")
    }

    @Test func fallsBackToMetaCharsetThenUTF8() {
        var page = Data("<html><head><meta charset=\"iso-8859-1\"></head><body>caf".utf8)
        page.append(0xE9)
        #expect(TextCoding.decode(page, contentType: "text/html").hasSuffix("café"))
        #expect(TextCoding.decode(Data("café".utf8), contentType: nil) == "café")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter TextCodingTests`
Expected: FAIL to compile, `cannot find 'TextCoding' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/TextCoding.swift`:

```swift
import Foundation

/// Converts upstream text to what a 1998 Latin-1 browser can display.
public enum TextCoding {
    public static let htmlContentType = "text/html; charset=windows-1252"
    public static let textContentType = "text/plain; charset=windows-1252"

    /// Windows-1252 bytes 0x80–0x9F that are printable, by Unicode scalar.
    private static let high: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
        0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
        0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
        0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    public static func windows1252(_ text: String, html: Bool) -> Data {
        var out = Data()
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x80 || (0xA0...0xFF).contains(value) {
                out.append(UInt8(value))
            } else if let byte = high[value] {
                out.append(byte)
            } else if html {
                out.append(contentsOf: Array("&#\(value);".utf8))
            } else {
                out.append(UInt8(ascii: "?"))
            }
        }
        return out
    }

    public static func decode(_ data: Data, contentType: String?) -> String {
        if let name = charset(in: contentType), let encoding = encoding(named: name),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        let prefix = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let range = prefix.range(of: #"charset=["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let name = prefix[range].replacingOccurrences(of: "charset=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let encoding = encoding(named: name), let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func charset(in contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("charset=") {
                return String(trimmed.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter TextCodingTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/TextCoding.swift apple/DataRoverKit/Tests/DataRoverWebTests/TextCodingTests.swift
git commit -m "Decode upstream text and encode Windows-1252 for the guest

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 7: Image transcoding

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/ImageTranscoder.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/ImageTranscoderTests.swift`

**Interfaces:**
- Produces:

```swift
public struct TranscodedImage: Equatable, Sendable { public var data: Data; public var contentType: String }
public enum ImageTranscoder {
    public static let maxWidth = 480
    public static let placeholderGIF: Data  // 1×1 transparent GIF
    public static func transcode(_ data: Data) -> TranscodedImage
}
public final class ImageCache: @unchecked Sendable {   // NSCache, 4 MB cost limit
    public init(limit: Int = 4 * 1024 * 1024)
    public func image(for key: String) -> TranscodedImage?
    public func store(_ image: TranscodedImage, for key: String)
}
```

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/ImageTranscoderTests.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DataRoverWeb

@Suite struct ImageTranscoderTests {
    private func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func photo(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {   // a gradient has far more than 256 colours
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.5, blue: CGFloat(x % 97) / 97, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()!
    }

    private func decoded(_ data: Data) -> (type: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return (type as String, image.width, image.height)
    }

    @Test func shrinksPhotosToJPEG() throws {
        let png = try #require(encode(photo(width: 1000, height: 500), as: .png))
        let out = ImageTranscoder.transcode(png)
        #expect(out.contentType == "image/jpeg")
        let info = try #require(decoded(out.data))
        #expect(info.width == 480 && info.height == 240)
    }

    @Test func keepsSmallFlatImagesAsGIFOnWhite() throws {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))   // right half stays transparent
        let png = try #require(encode(context.makeImage()!, as: .png))
        let out = ImageTranscoder.transcode(png)
        #expect(out.contentType == "image/gif")
        let info = try #require(decoded(out.data))
        #expect(info.width == 64 && info.height == 32)
    }

    @Test func decodesWebP() throws {
        // 1×1 lossless WebP (the widely used feature-detection sample).
        let webp = try #require(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="))
        let out = ImageTranscoder.transcode(webp)
        #expect(out.contentType == "image/gif")
        #expect(decoded(out.data)?.width == 1)
    }

    @Test func decodesAVIFWhenTheSystemCanWriteIt() throws {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(UTType.avif.identifier) else { return }
        let avif = try #require(encode(photo(width: 600, height: 300), as: .avif))
        let out = ImageTranscoder.transcode(avif)
        #expect(decoded(out.data)?.width == 480)
    }

    @Test func replacesUndecodableImagesWithAPlaceholder() {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8)
        #expect(ImageTranscoder.transcode(svg) == TranscodedImage(data: ImageTranscoder.placeholderGIF, contentType: "image/gif"))
    }

    @Test func cachesByKey() {
        let cache = ImageCache(limit: 1024)
        let image = TranscodedImage(data: Data([1, 2, 3]), contentType: "image/gif")
        cache.store(image, for: "http://e.com/a.png")
        #expect(cache.image(for: "http://e.com/a.png") == image)
        #expect(cache.image(for: "http://e.com/b.png") == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter ImageTranscoderTests`
Expected: FAIL to compile, `cannot find 'ImageTranscoder' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/ImageTranscoder.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct TranscodedImage: Equatable, Sendable {
    public var data: Data
    public var contentType: String
    public init(data: Data, contentType: String) { self.data = data; self.contentType = contentType }
}

/// Converts any image ImageIO can decode into a small GIF or JPEG.
public enum ImageTranscoder {
    public static let maxWidth = 480
    public static let placeholderGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")!

    private static var placeholder: TranscodedImage { TranscodedImage(data: placeholderGIF, contentType: "image/gif") }

    public static func transcode(_ data: Data) -> TranscodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return placeholder }
        let width = min(full.width, maxWidth)
        let height = max(1, Int((Double(full.height) * Double(width) / Double(full.width)).rounded()))
        let hadAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(full.alphaInfo)

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return placeholder }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)       // flatten onto white
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else { return placeholder }

        let useGIF = hadAlpha || colourCount(context, limit: 257) <= 256
        let type = useGIF ? UTType.gif : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            return placeholder
        }
        let properties = useGIF ? nil : [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary
        CGImageDestinationAddImage(destination, flat, properties)
        guard CGImageDestinationFinalize(destination) else { return placeholder }
        return TranscodedImage(data: out as Data, contentType: useGIF ? "image/gif" : "image/jpeg")
    }

    /// Distinct RGB colours in the bitmap, counting no higher than `limit`.
    private static func colourCount(_ context: CGContext, limit: Int) -> Int {
        guard let base = context.data else { return limit }
        let pixels = base.bindMemory(to: UInt32.self, capacity: context.width * context.height)
        var seen = Set<UInt32>()
        for index in 0..<(context.width * context.height) {
            seen.insert(pixels[index] & 0x00FF_FFFF)
            if seen.count >= limit { break }
        }
        return seen.count
    }
}

/// Transcoded images by upstream URL; pages reuse icons and logos.
public final class ImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, Box>()
    private final class Box { let image: TranscodedImage; init(_ image: TranscodedImage) { self.image = image } }

    public init(limit: Int = 4 * 1024 * 1024) { cache.totalCostLimit = limit }

    public func image(for key: String) -> TranscodedImage? { cache.object(forKey: key as NSString)?.image }

    public func store(_ image: TranscodedImage, for key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.data.count)
    }
}
```

(The colour mask assumes the `noneSkipLast` RGBX layout on little-endian arm64, where the skipped byte is the high byte of each `UInt32`.)

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter ImageTranscoderTests`
Expected: 6 tests pass (the AVIF test passes trivially where the system cannot write AVIF).

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/ImageTranscoder.swift apple/DataRoverKit/Tests/DataRoverWebTests/ImageTranscoderTests.swift
git commit -m "Transcode web images to small GIF or JPEG

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 8: Page simplifier

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/HTMLCleaning.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/PageSimplifier.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/PageSimplifierTests.swift`

**Interfaces:**
- Consumes: `HeaderRewriter.downgrade` (Task 5), `TextCoding.htmlContentType` (Task 6), `ImageTranscoder.maxWidth` (Task 7).
- Produces:

```swift
enum HTMLCleaning {
    static let startPageURL = "http://10.0.2.2/"
    static func downgradedAbsolute(_ element: Element, attribute: String) throws -> String?
    static func rewriteLinks(in document: Document, pageURL: URL) throws
    static func fixImages(in document: Document) throws
    static func setCharset(_ document: Document) throws
    static func readerURL(for pageURL: URL) -> String   // http URL + mcreader=1
    static func serialize(_ document: Document) throws -> String
}
public enum PageSimplifier {
    public static let budget = 150_000
    public static func simplify(html: String, pageURL: URL, budget: Int = PageSimplifier.budget) throws -> String
}
```

`pageURL` is the upstream URL actually fetched (usually `https://…`).

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/PageSimplifierTests.swift`:

```swift
import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct PageSimplifierTests {
    private let page = URL(string: "https://news.example/story/1")!

    private func simplify(_ body: String, head: String = "", budget: Int = PageSimplifier.budget) throws -> String {
        try PageSimplifier.simplify(html: "<html><head>\(head)</head><body>\(body)</body></html>", pageURL: page, budget: budget)
    }

    @Test func removesHeavyAndHiddenElements() throws {
        let out = try simplify("""
        <script>x()</script><noscript>n</noscript><style>p{}</style><iframe src="a"></iframe><svg></svg>
        <video></video><audio></audio><canvas></canvas><template>t</template>
        <div hidden>h</div><div aria-hidden="true">a</div><div style="display:none">d</div>
        <img src="/px.gif" width="1" height="1"><div id="cookie-banner">Accept cookies</div>
        <p>Keep me</p>
        """, head: "<link rel=\"stylesheet\" href=\"/s.css\">")
        for gone in ["<script", "<noscript", "<style", "<iframe", "<svg", "<video", "<audio", "<canvas",
                     "<template", ">h<", ">a<", ">d<", "px.gif", "Accept cookies", "s.css"] {
            #expect(!out.contains(gone), "\(gone)")
        }
        #expect(out.contains("Keep me"))
    }

    @Test func rewritesLinksToAbsoluteHTTP() throws {
        let out = try simplify("""
        <a href="/a">rel</a><a href="https://other.example/b">abs</a><a href="//cdn.example/c">proto</a>
        <a href="javascript:void(0)">js</a><form action="/search"></form><form></form>
        """)
        #expect(out.contains("href=\"http://news.example/a\""))
        #expect(out.contains("href=\"http://other.example/b\""))
        #expect(out.contains("href=\"http://cdn.example/c\""))
        #expect(!out.contains("javascript:"))
        #expect(out.contains("action=\"http://news.example/search\""))
        #expect(out.contains("action=\"http://news.example/story/1\""))
    }

    @Test func honoursBaseHref() throws {
        let out = try simplify("<a href=\"x\">x</a><img src=\"i.png\">", head: "<base href=\"https://static.example/dir/\">")
        #expect(out.contains("href=\"http://static.example/dir/x\""))
        #expect(out.contains("src=\"http://static.example/dir/i.png\""))
    }

    @Test func picksOneImageSourceAndCapsItsSize() throws {
        let out = try simplify("""
        <img srcset="/s.jpg 320w, /m.jpg 640w, /l.jpg 1280w" sizes="100vw" loading="lazy" width="1280" height="640">
        <img src="data:image/gif;base64,R0lGOD" data-src="/lazy.jpg">
        """)
        #expect(out.contains("src=\"http://news.example/s.jpg\""))
        #expect(out.contains("width=\"480\""))
        #expect(out.contains("height=\"240\""))
        #expect(!out.contains("srcset") && !out.contains("loading="))
        #expect(out.contains("src=\"http://news.example/lazy.jpg\""))
    }

    @Test func flattensMenusAndStripsPresentationalAttributes() throws {
        let out = try simplify("""
        <nav class="menu"><ul><li><a href="/n">News</a></li><li><a href="/s">Sport</a></li></ul></nav>
        <p class="x" style="color:red" onclick="go()">Text</p>
        """)
        #expect(!out.contains("<nav"))
        #expect(out.contains("News</a> | <a"))
        #expect(!out.contains("class=") && !out.contains("style=") && !out.contains("onclick"))
    }

    @Test func addsTheToolbarAndCharset() throws {
        let out = try simplify("<p>x</p>", head: "<meta charset=\"utf-8\">")
        #expect(out.contains("href=\"http://news.example/story/1?mcreader=1\">Reader view</a>"))
        #expect(out.contains("href=\"http://10.0.2.2/\">Start page</a>"))
        #expect(out.contains("charset=windows-1252"))
        #expect(!out.contains("charset=\"utf-8\""))
    }

    @Test func shortensPagesOverBudget() throws {
        let paragraphs = (0..<400).map { "<p>Paragraph \($0) " + String(repeating: "word ", count: 40) + "</p>" }.joined()
        let out = try simplify("<div><div>\(paragraphs)</div></div>", budget: 20_000)
        #expect(out.utf8.count < 22_000)
        #expect(out.contains("Paragraph 0 "))
        #expect(!out.contains("Paragraph 399 "))
        #expect(out.contains("Page shortened."))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter PageSimplifierTests`
Expected: FAIL to compile, `cannot find 'PageSimplifier' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/HTMLCleaning.swift`:

```swift
import Foundation
import SwiftSoup

/// DOM helpers shared by the simplifier and the reader view.
enum HTMLCleaning {
    static let startPageURL = "http://10.0.2.2/"

    /// The attribute as an absolute http:// URL, or nil for script and empty links.
    static func downgradedAbsolute(_ element: Element, attribute: String) throws -> String? {
        let raw = try element.attr(attribute).trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw.lowercased().hasPrefix("javascript:") { return nil }
        if raw.hasPrefix("#") || raw.lowercased().hasPrefix("mailto:") { return raw }
        let absolute = try element.absUrl(attribute)
        return absolute.isEmpty ? nil : HeaderRewriter.downgrade(absolute)
    }

    static func rewriteLinks(in document: Document, pageURL: URL) throws {
        for attribute in ["href", "src", "action"] {
            for element in try document.select("[\(attribute)]").array() {
                if element.tagName() == "base" { continue }
                if let url = try downgradedAbsolute(element, attribute: attribute) {
                    try element.attr(attribute, url)
                } else {
                    try element.removeAttr(attribute)
                }
            }
        }
        for form in try document.select("form:not([action])").array() {
            try form.attr("action", HeaderRewriter.downgrade(pageURL.absoluteString))
        }
        try document.select("base").remove()
    }

    /// One real source per image, sized for a 480-pixel screen. Run before
    /// `rewriteLinks` so chosen sources are resolved with the others.
    static func fixImages(in document: Document) throws {
        for image in try document.select("img").array() {
            let src = try image.attr("src")
            let lazy = try image.attr("data-src")
            if (src.isEmpty || src.hasPrefix("data:")), !lazy.isEmpty {
                try image.attr("src", lazy)
            } else if src.isEmpty, let candidate = try smallestCandidate(image.attr("srcset")) {
                try image.attr("src", candidate)
            }
            for attribute in ["srcset", "sizes", "loading", "decoding", "data-src", "data-srcset"] {
                try image.removeAttr(attribute)
            }
            if let width = Int(try image.attr("width")), width > ImageTranscoder.maxWidth {
                if let height = Int(try image.attr("height")), height > 0 {
                    try image.attr("height", String(height * ImageTranscoder.maxWidth / width))
                }
                try image.attr("width", String(ImageTranscoder.maxWidth))
            }
        }
    }

    private static func smallestCandidate(_ srcset: String) -> String? {
        srcset.split(separator: ",")
            .compactMap { entry -> (String, Int)? in
                let parts = entry.split(separator: " ", omittingEmptySubsequences: true)
                guard let url = parts.first else { return nil }
                let width = parts.dropFirst().first.flatMap { Int($0.dropLast()) } ?? Int.max
                return (String(url), width)
            }
            .min { $0.1 < $1.1 }?.0
    }

    static func setCharset(_ document: Document) throws {
        try document.select("meta[charset], meta[http-equiv]").remove()
        try document.head()?.prepend("<meta http-equiv=\"Content-Type\" content=\"\(TextCoding.htmlContentType)\">")
    }

    static func readerURL(for pageURL: URL) -> String {
        let http = HeaderRewriter.downgrade(pageURL.absoluteString)
        return http + (pageURL.query == nil ? "?" : "&") + "mcreader=1"
    }

    static func serialize(_ document: Document) throws -> String {
        document.outputSettings().prettyPrint(pretty: false)
        return try document.outerHtml()
    }
}
```

`apple/DataRoverKit/Sources/DataRoverWeb/PageSimplifier.swift`:

```swift
import Foundation
import SwiftSoup

/// Keeps a page's structure but removes what a 1998 browser cannot use.
public enum PageSimplifier {
    public static let budget = 150_000

    private static let removed = [
        "script", "noscript", "style", "link[rel~=stylesheet]", "link[rel~=preload]", "iframe", "svg",
        "video", "audio", "canvas", "source", "template", "object", "embed",
        "[hidden]", "[aria-hidden=true]", "[style*=\"display:none\"]", "[style*=\"display: none\"]",
        "img[width=1]", "img[height=1]",
        "[id*=cookie]", "[class*=cookie]", "[id*=consent]", "[class*=consent]",
    ].joined(separator: ", ")

    public static func simplify(html: String, pageURL: URL, budget: Int = PageSimplifier.budget) throws -> String {
        let document = try SwiftSoup.parse(html, pageURL.absoluteString)
        try document.select(removed).remove()
        try flattenMenus(document)
        try HTMLCleaning.fixImages(in: document)
        try HTMLCleaning.rewriteLinks(in: document, pageURL: pageURL)
        try stripPresentation(document)
        try HTMLCleaning.setCharset(document)
        let reader = HTMLCleaning.readerURL(for: pageURL)
        // Trim before adding the toolbar, so a page wrapped in one <div> is
        // trimmed inside that wrapper rather than removed whole.
        try enforce(budget: budget, on: document, reader: reader)
        try document.body()?.prepend(
            "<p><a href=\"\(reader)\">Reader view</a> | <a href=\"\(HTMLCleaning.startPageURL)\">Start page</a></p><hr>")
        return try HTMLCleaning.serialize(document)
    }

    private static func flattenMenus(_ document: Document) throws {
        for menu in try document.select("nav, header").array() {
            let links = try menu.select("a[href]").array()
            guard !links.isEmpty else { try menu.remove(); continue }
            let html = try links.map { try $0.outerHtml() }.joined(separator: " | ")
            try menu.before("<p>\(html)</p>")
            try menu.remove()
        }
    }

    private static func stripPresentation(_ document: Document) throws {
        for element in try document.getAllElements().array() {
            guard let attributes = element.getAttributes() else { continue }
            for attribute in attributes.asList() {
                let key = attribute.getKey().lowercased()
                if key == "style" || key == "class" || key.hasPrefix("on") {
                    try element.removeAttr(attribute.getKey())
                }
            }
        }
    }

    /// Drops trailing content until the page fits, descending through
    /// single-child wrappers so one outer <div> does not take everything.
    private static func enforce(budget: Int, on document: Document, reader: String) throws {
        guard let body = document.body() else { return }
        var size = try HTMLCleaning.serialize(document).utf8.count
        guard size > budget else { return }
        while size > budget {
            var container = body
            while container.children().size() == 1, let only = container.children().first() { container = only }
            guard container.children().size() > 1, let last = container.children().last() else { break }
            size -= try last.outerHtml().utf8.count
            try last.remove()
        }
        try body.append("<hr><p>Page shortened. <a href=\"\(reader)\">Reader view</a></p>")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter PageSimplifierTests`
Expected: 7 tests pass. If SwiftSoup's installed version names an API differently (for example `prettyPrint(pretty:)`), follow the compiler's fix-it; do not change the tested behaviour.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/HTMLCleaning.swift apple/DataRoverKit/Sources/DataRoverWeb/PageSimplifier.swift \
  apple/DataRoverKit/Tests/DataRoverWebTests/PageSimplifierTests.swift
git commit -m "Simplify modern pages for Web Browser 4.0

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 9: Reader view

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/ReaderExtractor.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/ReaderExtractorTests.swift`

**Interfaces:**
- Consumes: `HTMLCleaning` (Task 8).
- Produces: `public enum ReaderExtractor { static let minimumScore: Double; static func extract(html: String, pageURL: URL) throws -> String? }` — nil when no candidate reaches `minimumScore`.

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/ReaderExtractorTests.swift`:

```swift
import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct ReaderExtractorTests {
    private let page = URL(string: "https://blog.example/post?id=4")!
    private let sentence = "Magic Cap was a pioneering operating system, with rooms, stamps, and a friendly metaphor. "

    @Test func keepsTheArticleAndDropsTheChrome() throws {
        let article = (0..<6).map { "<p>\($0) \(String(repeating: sentence, count: 3))</p>" }.joined()
        let html = """
        <html><head><title>A history</title></head><body>
        <div class="sidebar"><a href="/1">One</a> <a href="/2">Two</a> <a href="/3">Three</a></div>
        <div class="post-content"><h2>Origins</h2>\(article)<img src="/fig.png" alt="Figure"></div>
        <div class="comments"><p>\(sentence)</p></div>
        <footer>© Example</footer></body></html>
        """
        let out = try #require(try ReaderExtractor.extract(html: html, pageURL: page))
        #expect(out.contains("<h1>A history</h1>"))
        #expect(out.contains("Origins"))
        #expect(out.contains("5 Magic Cap"))
        #expect(out.contains("src=\"http://blog.example/fig.png\""))
        #expect(!out.contains("One</a>"))
        #expect(!out.contains("© Example"))
        #expect(out.contains("href=\"http://blog.example/post?id=4\">Original page</a>"))
        #expect(!out.contains("class="))
        #expect(out.contains("charset=windows-1252"))
    }

    @Test func returnsNilWithoutARealArticle() throws {
        let html = "<html><body><a href=\"/a\">A</a> <a href=\"/b\">B</a><p>Short.</p></body></html>"
        #expect(try ReaderExtractor.extract(html: html, pageURL: page) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter ReaderExtractorTests`
Expected: FAIL to compile, `cannot find 'ReaderExtractor' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/ReaderExtractor.swift`:

```swift
import Foundation
import SwiftSoup

/// A small Readability-style extractor: keep the main article only.
public enum ReaderExtractor {
    public static let minimumScore = 20.0

    private static let positive = ["article", "body", "content", "entry", "main", "page", "post", "text", "blog", "story"]
    private static let negative = ["comment", "footer", "sidebar", "promo", "related", "share", "nav", "menu",
                                   "banner", "widget", "ad-", "sponsor", "social", "subscribe"]
    private static let allowed: Set<String> = ["p", "h1", "h2", "h3", "h4", "ul", "ol", "li", "blockquote",
                                               "img", "a", "pre", "br", "em", "strong", "b", "i"]

    public static func extract(html: String, pageURL: URL) throws -> String? {
        let document = try SwiftSoup.parse(html, pageURL.absoluteString)
        try document.select("script, style, noscript, nav, footer, aside, form, iframe, svg").remove()

        var scores: [ObjectIdentifier: (element: Element, score: Double)] = [:]
        func add(_ element: Element?, _ amount: Double) {
            guard let element else { return }
            let key = ObjectIdentifier(element)
            let base = scores[key]?.score ?? classWeight(element)
            scores[key] = (element, base + amount)
        }
        for paragraph in try document.select("p, pre, td").array() {
            let text = try paragraph.text()
            guard text.count >= 25 else { continue }
            let points = 1 + Double(text.filter { $0 == "," }.count) + min(Double(text.count) / 100, 3)
            add(paragraph.parent(), points)
            add(paragraph.parent()?.parent(), points / 2)
        }
        let ranked = try scores.values.map { entry in
            (entry.element, entry.score * (1 - (try linkDensity(entry.element))))
        }
        guard let (best, bestScore) = ranked.max(by: { $0.1 < $1.1 }), bestScore >= minimumScore else { return nil }

        var kept = [best]
        if let parent = best.parent() {
            let threshold = max(10, bestScore * 0.2)
            kept = try parent.children().array().filter { sibling in
                if sibling === best { return true }
                let score = ranked.first { $0.0 === sibling }?.1 ?? 0
                return score >= threshold
            }
        }

        let title = try document.title()
        let output = try SwiftSoup.parse("<html><head><title></title></head><body></body></html>", pageURL.absoluteString)
        try output.title(title)
        let body = output.body()!
        try body.append("<p><a href=\"\(HeaderRewriter.downgrade(pageURL.absoluteString))\">Original page</a> | "
                        + "<a href=\"\(HTMLCleaning.startPageURL)\">Start page</a></p><hr>")
        if !title.isEmpty { try body.append("<h1></h1>"); try body.children().last()?.text(title) }
        for element in kept { try body.append(try element.outerHtml()) }
        try clean(body)
        try HTMLCleaning.fixImages(in: output)
        try HTMLCleaning.rewriteLinks(in: output, pageURL: pageURL)
        try HTMLCleaning.setCharset(output)
        return try HTMLCleaning.serialize(output)
    }

    private static func classWeight(_ element: Element) -> Double {
        let names = ((try? element.className()) ?? "") + " " + element.id()
        let lower = names.lowercased()
        var weight = 0.0
        if positive.contains(where: lower.contains) { weight += 25 }
        if negative.contains(where: lower.contains) { weight -= 25 }
        return weight
    }

    private static func linkDensity(_ element: Element) throws -> Double {
        let total = try element.text().count
        guard total > 0 else { return 1 }
        let linked = try element.select("a").array().reduce(0) { $0 + (try $1.text().count) }
        return Double(linked) / Double(total)
    }

    /// Unwrap everything outside the allow-list; keep only link and image attributes.
    private static func clean(_ body: Element) throws {
        for element in try body.getAllElements().array().reversed() where element !== body {
            if !allowed.contains(element.tagName()) {
                try element.unwrap()
                continue
            }
            guard let attributes = element.getAttributes() else { continue }
            for attribute in attributes.asList() where !["href", "src", "alt"].contains(attribute.getKey()) {
                try element.removeAttr(attribute.getKey())
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter ReaderExtractorTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/ReaderExtractor.swift apple/DataRoverKit/Tests/DataRoverWebTests/ReaderExtractorTests.swift
git commit -m "Add reader view for the web proxy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 10: Upstream fetcher

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/UpstreamFetcher.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/StubURLProtocol.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/UpstreamFetcherTests.swift`

**Interfaces:**
- Consumes: `ProxyRequest`, `HTTPHeader` (Task 4), `DestinationPolicy` (Task 3).
- Produces:

```swift
public struct UpstreamResponse: Equatable, Sendable {
    public var status: Int; public var headers: [HTTPHeader]; public var body: Data; public var url: URL
}
public enum UpstreamError: Error, Equatable { case forbidden, tooLarge, unreachable(String) }
public protocol UpstreamFetching: Sendable { func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse }
public final class UpstreamFetcher: UpstreamFetching {
    public static let maxResponseBytes = 8 * 1024 * 1024
    public static let userAgent: String
    public init(configuration: URLSessionConfiguration = .ephemeral, policy: @escaping @Sendable (String) -> Bool = DestinationPolicy.allows)
}
```

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/StubURLProtocol.swift`:

```swift
import Foundation

/// Serves canned responses by URL for URLSession tests. Tests using it must
/// be in a `.serialized` suite: the handler is process-wide.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case response(Int, [String: String], Data), failure(URLError.Code) }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            recorded.httpBody = data
        }
        Self.seen.append(recorded)
        switch Self.replies[request.url!.absoluteString] ?? .failure(.cannotFindHost) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
```

`apple/DataRoverKit/Tests/DataRoverWebTests/UpstreamFetcherTests.swift`:

```swift
import Foundation
import Testing
@testable import DataRoverWeb

@Suite(.serialized) struct UpstreamFetcherTests {
    private func fetcher(allow: Bool = true) -> UpstreamFetcher {
        StubURLProtocol.seen = []
        return UpstreamFetcher(configuration: StubURLProtocol.configuration(), policy: { _ in allow })
    }

    @Test func fetchesOverHTTPSAndSendsGuestHeaders() async throws {
        StubURLProtocol.replies = ["https://e.com/p?q=1": .response(200, ["Content-Type": "text/html"], Data("ok".utf8))]
        let request = ProxyRequest(method: "GET", host: "e.com", target: "/p?q=1",
                                   headers: [HTTPHeader(name: "Cookie", value: "a=b"),
                                             HTTPHeader(name: "Referer", value: "http://e.com/"),
                                             HTTPHeader(name: "User-Agent", value: "Mozilla/3.02")])
        let response = try await fetcher().fetch(request)
        #expect(response.status == 200 && response.body == Data("ok".utf8))
        #expect(response.url.absoluteString == "https://e.com/p?q=1")
        let sent = try #require(StubURLProtocol.seen.first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == "a=b")
        #expect(sent.value(forHTTPHeaderField: "Referer") == "https://e.com/")
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == UpstreamFetcher.userAgent)
    }

    @Test func fallsBackToHTTPOnlyWhenTLSFails() async throws {
        StubURLProtocol.replies = ["https://old.example/": .failure(.secureConnectionFailed),
                                   "http://old.example/": .response(200, [:], Data("retro".utf8))]
        let response = try await fetcher().fetch(ProxyRequest(method: "GET", host: "old.example", target: "/"))
        #expect(response.url.absoluteString == "http://old.example/")
        #expect(response.body == Data("retro".utf8))
    }

    @Test func doesNotFallBackOnHTTPErrors() async throws {
        StubURLProtocol.replies = ["https://e.com/missing": .response(404, [:], Data())]
        let response = try await fetcher().fetch(ProxyRequest(method: "GET", host: "e.com", target: "/missing"))
        #expect(response.status == 404)
        #expect(StubURLProtocol.seen.count == 1)
    }

    @Test func returnsRedirectsUnfollowed() async throws {
        StubURLProtocol.replies = ["https://e.com/old": .response(301, ["Location": "https://e.com/new"], Data())]
        let response = try await fetcher().fetch(ProxyRequest(method: "GET", host: "e.com", target: "/old"))
        #expect(response.status == 301)
        #expect(response.headers.contains(HTTPHeader(name: "Location", value: "https://e.com/new")))
    }

    @Test func forwardsFormBodies() async throws {
        StubURLProtocol.replies = ["https://e.com/f": .response(200, [:], Data())]
        let request = ProxyRequest(method: "POST", host: "e.com", target: "/f",
                                   headers: [HTTPHeader(name: "Content-Type", value: "application/x-www-form-urlencoded")],
                                   body: Data("q=magic".utf8))
        _ = try await fetcher().fetch(request)
        #expect(StubURLProtocol.seen.first?.httpMethod == "POST")
        #expect(StubURLProtocol.seen.first?.httpBody == Data("q=magic".utf8))
    }

    @Test func enforcesPolicyAndSizeCap() async throws {
        await #expect(throws: UpstreamError.forbidden) {
            try await fetcher(allow: false).fetch(ProxyRequest(method: "GET", host: "e.com", target: "/"))
        }
        StubURLProtocol.replies = ["https://e.com/big": .response(200, [:], Data(count: UpstreamFetcher.maxResponseBytes + 1))]
        await #expect(throws: UpstreamError.tooLarge) {
            try await fetcher().fetch(ProxyRequest(method: "GET", host: "e.com", target: "/big"))
        }
    }

    @Test func reportsUnreachableHosts() async throws {
        StubURLProtocol.replies = [:]
        await #expect(throws: UpstreamError.self) {
            try await fetcher().fetch(ProxyRequest(method: "GET", host: "nowhere.example", target: "/"))
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter UpstreamFetcherTests`
Expected: FAIL to compile, `cannot find 'UpstreamFetcher' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/UpstreamFetcher.swift`:

```swift
import Foundation

public struct UpstreamResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [HTTPHeader]
    public var body: Data
    public var url: URL
    public init(status: Int, headers: [HTTPHeader], body: Data, url: URL) {
        self.status = status; self.headers = headers; self.body = body; self.url = url
    }
}

public enum UpstreamError: Error, Equatable {
    case forbidden
    case tooLarge
    case unreachable(String)
}

public protocol UpstreamFetching: Sendable {
    func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse
}

/// Fetches a guest request from the real site, HTTPS first.
public final class UpstreamFetcher: UpstreamFetching {
    public static let maxResponseBytes = 8 * 1024 * 1024
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private static let tlsFailures: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
        .cannotConnectToHost,
    ]

    private let session: URLSession
    private let policy: @Sendable (String) -> Bool

    public init(configuration: URLSessionConfiguration = .ephemeral,
                policy: @escaping @Sendable (String) -> Bool = DestinationPolicy.allows) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        session = URLSession(configuration: configuration)
        self.policy = policy
    }

    public func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse {
        let hostName = request.host.split(separator: ":").first.map(String.init) ?? request.host
        guard policy(hostName) else { throw UpstreamError.forbidden }
        do {
            return try await load(request, scheme: "https")
        } catch let error as URLError where Self.tlsFailures.contains(error.code) {
            return try await load(request, scheme: "http")
        }
    }

    private func load(_ request: ProxyRequest, scheme: String) async throws -> UpstreamResponse {
        guard let url = URL(string: "\(scheme)://\(request.host)\(request.target)") else {
            throw UpstreamError.unreachable("That address is not valid.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for header in request.headers {
            switch header.name.lowercased() {
            case "user-agent", "content-length": continue
            case "referer": urlRequest.setValue(header.value.replacingOccurrences(of: "http://", with: "https://"),
                                                forHTTPHeaderField: header.name)
            default: urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
            }
        }
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if request.method == "POST" { urlRequest.httpBody = request.body }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: NoRedirects())
        } catch let error as URLError where Self.tlsFailures.contains(error.code) && scheme == "https" {
            throw error
        } catch let error as URLError {
            throw UpstreamError.unreachable(error.localizedDescription)
        }
        guard data.count <= Self.maxResponseBytes else { throw UpstreamError.tooLarge }
        guard let http = response as? HTTPURLResponse else { throw UpstreamError.unreachable("No HTTP response.") }
        let headers = http.allHeaderFields.compactMap { key, value -> HTTPHeader? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return HTTPHeader(name: name, value: text)
        }
        return UpstreamResponse(status: http.statusCode, headers: headers, body: data, url: url)
    }
}

/// The guest browser follows redirects itself, so its address bar stays right.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter UpstreamFetcherTests`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/UpstreamFetcher.swift \
  apple/DataRoverKit/Tests/DataRoverWebTests/StubURLProtocol.swift apple/DataRoverKit/Tests/DataRoverWebTests/UpstreamFetcherTests.swift
git commit -m "Fetch guest requests upstream over HTTPS with an HTTP fallback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 11: Proxy pipeline, start page and error pages

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/StartPage.swift`
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/ProxyPipeline.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/ProxyPipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 4–10.
- Produces:

```swift
public enum StartPage { public static let host = "10.0.2.2"; public static func html() -> String }
public final class ProxyPipeline: Sendable {
    public init(fetcher: UpstreamFetching, simplify: @escaping @Sendable () -> Bool, images: ImageCache = ImageCache())
    public func respond(to request: ProxyRequest) async -> ProxyResponse
    public static func errorPage(status: Int, reason: String, title: String, detail: String) -> ProxyResponse
}
```

Every response carries `Content-Type`, `Content-Length` (of the body that would be sent for GET) and `Connection: close`; callers send the body unless the method is `HEAD`.

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/ProxyPipelineTests.swift`:

```swift
import Foundation
import Testing
@testable import DataRoverWeb

private struct FakeFetcher: UpstreamFetching {
    var result: @Sendable (ProxyRequest) throws -> UpstreamResponse
    func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse { try result(request) }
}

@Suite struct ProxyPipelineTests {
    private func pipeline(simplify: Bool = true, _ result: @escaping @Sendable (ProxyRequest) throws -> UpstreamResponse) -> ProxyPipeline {
        ProxyPipeline(fetcher: FakeFetcher(result: result), simplify: { simplify })
    }
    private func html(_ body: String, type: String? = "text/html; charset=utf-8", url: String = "https://e.com/") -> UpstreamResponse {
        UpstreamResponse(status: 200, headers: type.map { [HTTPHeader(name: "Content-Type", value: $0)] } ?? [],
                         body: Data(body.utf8), url: URL(string: url)!)
    }
    private func header(_ response: ProxyResponse, _ name: String) -> String? {
        response.headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }
    private func text(_ response: ProxyResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    @Test func servesTheStartPage() async {
        let response = await pipeline { _ in throw UpstreamError.forbidden }
            .respond(to: ProxyRequest(method: "GET", host: StartPage.host, target: "/"))
        #expect(response.status == 200)
        #expect(text(response).contains("action=\"http://html.duckduckgo.com/html/\""))
        #expect(header(response, "Content-Type") == TextCoding.htmlContentType)
    }

    @Test func simplifiesHTMLAndSetsFraming() async {
        let response = await pipeline { _ in self.html("<html><body><script>x</script><p>Café</p></body></html>") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(!text(response).contains("<script"))
        #expect(response.body.contains(0xE9))            // é as one Windows-1252 byte
        #expect(header(response, "Content-Length") == String(response.body.count))
        #expect(header(response, "Connection") == "close")
    }

    @Test func treatsUntypedMarkupAsHTMLAndHonoursLatin1() async {
        var latin1 = Data("<html><body><p>caf".utf8); latin1.append(0xE9); latin1.append(Data("</p></body></html>".utf8))
        let untyped = await pipeline { _ in self.html("<html><body><p>x</p></body></html>", type: nil) }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(header(untyped, "Content-Type") == TextCoding.htmlContentType)
        let typed = await pipeline { _ in
            UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/html; charset=ISO-8859-1")],
                             body: latin1, url: URL(string: "https://e.com/")!)
        }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(typed.body.contains(0xE9))
        #expect(!text(typed).contains("\u{FFFD}"))
    }

    @Test func usesReaderViewWhenAsked() async {
        let sentence = "Magic Cap was a pioneering operating system, with rooms, stamps, and a friendly metaphor. "
        let article = "<html><head><title>T</title></head><body><div class=\"sidebar\"><a href=\"/x\">X</a></div><div class=\"post\">"
            + (0..<6).map { _ in "<p>\(String(repeating: sentence, count: 3))</p>" }.joined() + "</div></body></html>"
        let response = await pipeline { _ in self.html(article) }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/", reader: true))
        #expect(text(response).contains("Original page"))
        #expect(!text(response).contains(">X</a>"))
    }

    @Test func passesHTMLThroughWithLinksRewrittenWhenSimplifyIsOff() async {
        let response = await pipeline(simplify: false) { _ in self.html("<script>k</script><a href=\"https://e.com/a\">a</a>") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(text(response).contains("<script>k</script>"))
        #expect(text(response).contains("http://e.com/a"))
    }

    @Test func emptiesStylesScriptsAndFonts() async {
        for type in ["text/css", "application/javascript", "text/javascript", "font/woff2", "application/font-woff"] {
            let response = await pipeline { _ in self.html("body{}", type: type) }
                .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/x"))
            #expect(response.status == 200 && response.body.isEmpty, "\(type)")
        }
    }

    @Test func rewritesRedirects() async {
        let response = await pipeline { _ in
            UpstreamResponse(status: 302, headers: [HTTPHeader(name: "Location", value: "https://e.com/b")],
                             body: Data(), url: URL(string: "https://e.com/a")!)
        }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/a"))
        #expect(response.status == 302)
        #expect(header(response, "Location") == "http://e.com/b")
    }

    @Test func turnsFailuresIntoReadablePages() async {
        let forbidden = await pipeline { _ in throw UpstreamError.forbidden }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(forbidden.status == 403 && text(forbidden).contains("isn't allowed"))
        let big = await pipeline { _ in throw UpstreamError.tooLarge }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(big.status == 502 && text(big).contains("too large"))
        let down = await pipeline { _ in throw UpstreamError.unreachable("The server is down.") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(down.status == 502 && text(down).contains("The server is down."))
    }

    @Test func headResponsesKeepHeadersForSerialization() async {
        let response = await pipeline { _ in throw UpstreamError.forbidden }
            .respond(to: ProxyRequest(method: "HEAD", host: "e.com", target: "/"))
        let wire = String(decoding: response.serialized(includeBody: false), as: UTF8.self)
        #expect(wire.hasPrefix("HTTP/1.0 403"))
        #expect(wire.hasSuffix("\r\n\r\n"))
        #expect(header(response, "Content-Length") == String(response.body.count))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter ProxyPipelineTests`
Expected: FAIL to compile, `cannot find 'ProxyPipeline' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/StartPage.swift`:

```swift
/// The proxy's own page at http://10.0.2.2/ — search and a few starting points.
public enum StartPage {
    public static let host = "10.0.2.2"

    public static func html() -> String {
        """
        <html><head><title>Start page</title></head><body>
        <h1>Web</h1>
        <form action="http://html.duckduckgo.com/html/" method="get">
        <input type="text" name="q" size="24"> <input type="submit" value="Search">
        </form>
        <p><a href="http://en.wikipedia.org/">Wikipedia</a><br>
        <a href="http://68k.news/">68k.news</a><br>
        <a href="http://lite.cnn.com/">CNN Lite</a><br>
        <a href="http://text.npr.org/">NPR text</a></p>
        <p>Pages are simplified to fit. If a page is still too big, use Reader view at the top of the page.</p>
        </body></html>
        """
    }
}
```

`apple/DataRoverKit/Sources/DataRoverWeb/ProxyPipeline.swift`:

```swift
import Foundation

/// Turns one guest request into one guest-ready response.
public final class ProxyPipeline: Sendable {
    private let fetcher: UpstreamFetching
    private let simplify: @Sendable () -> Bool
    private let images: ImageCache

    public init(fetcher: UpstreamFetching, simplify: @escaping @Sendable () -> Bool, images: ImageCache = ImageCache()) {
        self.fetcher = fetcher; self.simplify = simplify; self.images = images
    }

    public func respond(to request: ProxyRequest) async -> ProxyResponse {
        if request.host == StartPage.host {
            guard request.target == "/" || request.target.hasPrefix("/?") else {
                return Self.errorPage(status: 404, reason: "Not Found", title: "Page not found",
                                      detail: "The start page is at http://10.0.2.2/.")
            }
            return Self.text(status: 200, reason: "OK", headers: [], html: StartPage.html())
        }
        do {
            return try transform(await fetcher.fetch(request), reader: request.reader)
        } catch UpstreamError.forbidden {
            return Self.errorPage(status: 403, reason: "Forbidden", title: "That address isn't allowed",
                                  detail: "The proxy only visits public websites.")
        } catch UpstreamError.tooLarge {
            return Self.errorPage(status: 502, reason: "Bad Gateway", title: "Page too large",
                                  detail: "The page is too large to load.")
        } catch UpstreamError.unreachable(let message) {
            return Self.errorPage(status: 502, reason: "Bad Gateway", title: "Couldn't load the page", detail: message)
        } catch {
            return Self.errorPage(status: 502, reason: "Bad Gateway", title: "Couldn't load the page",
                                  detail: error.localizedDescription)
        }
    }

    private func transform(_ upstream: UpstreamResponse, reader: Bool) throws -> ProxyResponse {
        let headers = HeaderRewriter.rewrite(upstream.headers).filter { $0.name.lowercased() != "content-type" }
        let contentType = upstream.headers.first { $0.name.lowercased() == "content-type" }?.value
        let mime = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? (upstream.body.first == UInt8(ascii: "<") ? "text/html" : "application/octet-stream")
        let reason = HTTPURLResponse.localizedString(forStatusCode: upstream.status).capitalized
        let enabled = simplify()

        switch mime {
        case "text/html", "application/xhtml+xml":
            let source = TextCoding.decode(upstream.body, contentType: contentType)
            let page: String
            if !enabled {
                page = HeaderRewriter.downgrade(source)
            } else if reader, let extracted = try ReaderExtractor.extract(html: source, pageURL: upstream.url) {
                page = extracted
            } else {
                page = try PageSimplifier.simplify(html: source, pageURL: upstream.url)
            }
            return Self.text(status: upstream.status, reason: reason, headers: headers, html: page)
        case "text/plain":
            let body = TextCoding.windows1252(TextCoding.decode(upstream.body, contentType: contentType), html: false)
            return Self.framed(status: upstream.status, reason: reason, headers: headers,
                               contentType: TextCoding.textContentType, body: body)
        case "text/css", "application/javascript", "text/javascript", "application/x-javascript":
            return Self.framed(status: 200, reason: "OK", headers: headers, contentType: mime, body: Data())
        case _ where mime.hasPrefix("font/") || mime.hasPrefix("application/font") || mime.contains("woff"):
            return Self.framed(status: 200, reason: "OK", headers: headers, contentType: mime, body: Data())
        case _ where mime.hasPrefix("image/") && enabled && upstream.status == 200:
            let key = upstream.url.absoluteString
            let image = images.image(for: key) ?? {
                let fresh = ImageTranscoder.transcode(upstream.body)
                images.store(fresh, for: key)
                return fresh
            }()
            return Self.framed(status: 200, reason: "OK", headers: headers, contentType: image.contentType, body: image.data)
        default:
            return Self.framed(status: upstream.status, reason: reason, headers: headers,
                               contentType: contentType ?? mime, body: upstream.body)
        }
    }

    public static func errorPage(status: Int, reason: String, title: String, detail: String) -> ProxyResponse {
        text(status: status, reason: reason, headers: [],
             html: "<html><head><title>\(escape(title))</title></head><body><h1>\(escape(title))</h1>"
                 + "<p>\(escape(detail))</p><p><a href=\"http://10.0.2.2/\">Start page</a></p></body></html>")
    }

    private static func text(status: Int, reason: String, headers: [HTTPHeader], html: String) -> ProxyResponse {
        framed(status: status, reason: reason, headers: headers, contentType: TextCoding.htmlContentType,
               body: TextCoding.windows1252(html, html: true))
    }

    private static func framed(status: Int, reason: String, headers: [HTTPHeader], contentType: String, body: Data) -> ProxyResponse {
        ProxyResponse(status: status, reason: reason.isEmpty ? "OK" : reason,
                      headers: headers + [HTTPHeader(name: "Content-Type", value: contentType),
                                          HTTPHeader(name: "Content-Length", value: String(body.count)),
                                          HTTPHeader(name: "Connection", value: "close")],
                      body: body)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter ProxyPipelineTests`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/StartPage.swift apple/DataRoverKit/Sources/DataRoverWeb/ProxyPipeline.swift \
  apple/DataRoverKit/Tests/DataRoverWebTests/ProxyPipelineTests.swift
git commit -m "Assemble the web proxy pipeline with start and error pages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 12: Loopback listener

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/WebProxy.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/WebProxyTests.swift`

**Interfaces:**
- Consumes: `RequestParser` (Task 4), `ProxyPipeline` (Task 11).
- Produces: `public final class WebProxy: @unchecked Sendable { public static let maxConnections = 8; public init(pipeline: ProxyPipeline); public func start() async throws -> UInt16; public func stop() }` — listens on 127.0.0.1 only, on a system-chosen port.

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/WebProxyTests.swift`:

```swift
import Foundation
import Network
import Testing
@testable import DataRoverWeb

private struct EchoFetcher: UpstreamFetching {
    func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse {
        UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                         body: Data("\(request.method) \(request.host)\(request.target)".utf8),
                         url: URL(string: "https://\(request.host)\(request.target)")!)
    }
}

/// Sends raw bytes to the proxy and returns everything until it closes.
private func exchange(port: UInt16, _ text: String) async throws -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    return try await withCheckedThrowingContinuation { continuation in
        var received = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { received.append(data) }
                if complete || error != nil {
                    connection.cancel()
                    continuation.resume(returning: String(decoding: received, as: UTF8.self))
                } else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in read() })
            } else if case .failed(let error) = state {
                continuation.resume(throwing: error)
            }
        }
        connection.start(queue: .global())
    }
}

@Suite struct WebProxyTests {
    @Test func servesARequestOverLoopback() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        let port = try await proxy.start()
        defer { proxy.stop() }
        #expect(port != 0)
        let reply = try await exchange(port: port, "GET /hello HTTP/1.0\r\nHost: example.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.0 200"))
        #expect(reply.hasSuffix("GET example.com/hello"))
    }

    @Test func omitsBodiesForHead() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        let port = try await proxy.start()
        defer { proxy.stop() }
        let reply = try await exchange(port: port, "HEAD /x HTTP/1.0\r\nHost: example.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.0 200") && reply.hasSuffix("\r\n\r\n"))
    }

    @Test func answersMalformedRequestsWithAnErrorPage() async throws {
        let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: EchoFetcher(), simplify: { true }))
        let port = try await proxy.start()
        defer { proxy.stop() }
        let reply = try await exchange(port: port, "BREW /pot HTTP/1.0\r\nHost: e.com\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.0 405"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter WebProxyTests`
Expected: FAIL to compile, `cannot find 'WebProxy' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/WebProxy.swift`:

```swift
import Foundation
import Network

/// The loopback HTTP server the patched libslirp sends guest port 80 to.
public final class WebProxy: @unchecked Sendable {
    public static let maxConnections = 8
    private let pipeline: ProxyPipeline
    private let queue = DispatchQueue(label: "com.example.datarover.web-proxy")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(pipeline: ProxyPipeline) { self.pipeline = pipeline }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard connections.count < Self.maxConnections else {
            send(ProxyPipeline.errorPage(status: 503, reason: "Service Unavailable", title: "Too many requests",
                                         detail: "Wait a moment and try again."), includeBody: true, on: connection)
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        queue.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            self.close(connection)
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            switch RequestParser.parse(accumulated) {
            case .complete(let request):
                Task {
                    let response = await self.pipeline.respond(to: request)
                    self.queue.async { self.send(response, includeBody: request.method != "HEAD", on: connection) }
                }
            case .invalid(let status):
                let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
                self.send(ProxyPipeline.errorPage(status: status, reason: reason, title: "Request not understood",
                                                  detail: "The browser sent a request the proxy can't handle."),
                          includeBody: true, on: connection)
            case .incomplete:
                if complete || error != nil { self.close(connection) } else { self.receive(on: connection, buffer: accumulated) }
            }
        }
    }

    private func send(_ response: ProxyResponse, includeBody: Bool, on connection: NWConnection) {
        connection.send(content: response.serialized(includeBody: includeBody), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter WebProxyTests`
Expected: 3 tests pass. Then run the whole package: `swift test --package-path apple/DataRoverKit` (all suites pass).

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/WebProxy.swift apple/DataRoverKit/Tests/DataRoverWebTests/WebProxyTests.swift
git commit -m "Serve the web proxy on host loopback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 13: Browser package downloads

**Files:**
- Create: `apple/DataRoverKit/Sources/DataRoverWeb/BrowserPackages.swift`
- Create: `apple/DataRoverKit/Tests/DataRoverWebTests/BrowserPackagesTests.swift`

**Interfaces:**
- Produces:

```swift
public struct BrowserPackage: Equatable, Sendable { public let name: String; public let url: URL; public let size: Int; public let sha256: String }
public enum BrowserPackages { public static let all: [BrowserPackage] }   // driver, browser, JavaScript, in install order
public enum PackageDownloadError: Error, Equatable { case download(String), checksumMismatch(String) }
public struct PackageDownloader: Sendable {
    public init(session: URLSession = .shared)
    public func ensure(_ package: BrowserPackage, in directory: URL) async throws -> URL
}
```

- [ ] **Step 1: Write the failing test**

`apple/DataRoverKit/Tests/DataRoverWebTests/BrowserPackagesTests.swift`:

```swift
import CryptoKit
import Foundation
import Testing
@testable import DataRoverWeb

@Suite(.serialized) struct BrowserPackagesTests {
    private let bytes = Data("fake package".utf8)
    private var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func downloader() -> PackageDownloader {
        StubURLProtocol.seen = []
        return PackageDownloader(session: URLSession(configuration: StubURLProtocol.configuration()))
    }

    @Test func listsThePinnedPackagesInInstallOrder() {
        #expect(BrowserPackages.all.map(\.name) == ["EtherLinkIII.pkg", "WebBrowser40.mc2", "MagicJavaScript.pkg"])
        #expect(BrowserPackages.all[1].sha256 == "b401b0f82beff0d945a4eb0361c8cf02aa16ec3fd79a3267edd46248c92bc706")
        #expect(BrowserPackages.all.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 })
    }

    @Test func downloadsAndVerifies() async throws {
        let package = BrowserPackage(name: "Test.pkg", url: URL(string: "https://p.example/Test.pkg")!,
                                     size: bytes.count, sha256: digest)
        StubURLProtocol.replies = [package.url.absoluteString: .response(200, [:], bytes)]
        let dir = try directory()
        let file = try await downloader().ensure(package, in: dir)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(file.lastPathComponent == "Test.pkg")
    }

    @Test func skipsFilesThatAlreadyVerify() async throws {
        let package = BrowserPackage(name: "Test.pkg", url: URL(string: "https://p.example/Test.pkg")!,
                                     size: bytes.count, sha256: digest)
        let dir = try directory()
        try bytes.write(to: dir.appendingPathComponent("Test.pkg"))
        StubURLProtocol.replies = [:]
        _ = try await downloader().ensure(package, in: dir)
        #expect(StubURLProtocol.seen.isEmpty)
    }

    @Test func rejectsAndDeletesMismatches() async throws {
        let package = BrowserPackage(name: "Bad.pkg", url: URL(string: "https://p.example/Bad.pkg")!,
                                     size: 3, sha256: String(repeating: "0", count: 64))
        StubURLProtocol.replies = [package.url.absoluteString: .response(200, [:], Data("bad".utf8))]
        let dir = try directory()
        await #expect(throws: PackageDownloadError.checksumMismatch("Bad.pkg")) {
            try await downloader().ensure(package, in: dir)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Bad.pkg").path))
    }

    @Test func reportsDownloadFailures() async throws {
        let package = BrowserPackage(name: "Gone.pkg", url: URL(string: "https://p.example/Gone.pkg")!, size: 1, sha256: digest)
        StubURLProtocol.replies = [package.url.absoluteString: .response(404, [:], Data())]
        await #expect(throws: PackageDownloadError.download("Gone.pkg")) {
            try await downloader().ensure(package, in: try directory())
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path apple/DataRoverKit --filter BrowserPackagesTests`
Expected: FAIL to compile, `cannot find 'BrowserPackages' in scope`.

- [ ] **Step 3: Implement**

`apple/DataRoverKit/Sources/DataRoverWeb/BrowserPackages.swift`:

```swift
import CryptoKit
import Foundation

public struct BrowserPackage: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let size: Int
    public let sha256: String
    public init(name: String, url: URL, size: Int, sha256: String) {
        self.name = name; self.url = url; self.size = size; self.sha256 = sha256
    }
}

/// Web Browser 4.0 and what it needs, fetched from their original host.
public enum BrowserPackages {
    public static let all: [BrowserPackage] = [
        BrowserPackage(name: "EtherLinkIII.pkg",
                       url: URL(string: "https://joshcarter.com/magic_cap/packages/EtherLinkIII.pkg")!, size: 65_624,
                       sha256: "c0b23f24a91e7b03f4adf1a356dc4356f4091284a424119bbdd9d89f72279b34"),
        BrowserPackage(name: "WebBrowser40.mc2",
                       url: URL(string: "https://joshcarter.com/magic_cap/packages/WebBrowser40.mc2")!, size: 508_892,
                       sha256: "b401b0f82beff0d945a4eb0361c8cf02aa16ec3fd79a3267edd46248c92bc706"),
        BrowserPackage(name: "MagicJavaScript.pkg",
                       url: URL(string: "https://joshcarter.com/magic_cap/packages/MagicJavaScript.pkg")!, size: 467_876,
                       sha256: "beb0de0cdb51207534c280c88402ec11972dd7dfce11cd08514adc92c2f6f406"),
    ]
}

public enum PackageDownloadError: Error, Equatable {
    case download(String)
    case checksumMismatch(String)
}

public struct PackageDownloader: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    /// The verified file in `directory`, downloading it only if needed.
    public func ensure(_ package: BrowserPackage, in directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(package.name)
        if let existing = try? Data(contentsOf: destination), Self.digest(existing) == package.sha256 {
            return destination
        }
        let data: Data
        do {
            let (body, response) = try await session.data(from: package.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PackageDownloadError.download(package.name) }
            data = body
        } catch let error as PackageDownloadError {
            throw error
        } catch {
            throw PackageDownloadError.download(package.name)
        }
        guard Self.digest(data) == package.sha256 else {
            try? FileManager.default.removeItem(at: destination)
            throw PackageDownloadError.checksumMismatch(package.name)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path apple/DataRoverKit --filter BrowserPackagesTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverWeb/BrowserPackages.swift apple/DataRoverKit/Tests/DataRoverWebTests/BrowserPackagesTests.swift
git commit -m "Download and verify the Web Browser 4.0 packages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 14: Session wiring, installer flow and controls

**Files:**
- Modify: `apple/DataRoverKit/Sources/DataRoverShell/EmulatorSession.swift`
- Modify: `apple/DataRoverKit/Sources/DataRoverShell/EmulatorControlsSheet.swift`

**Interfaces:**
- Consumes: `coreCreate(…httpRedirectPort:)` (Task 2), `WebProxy`, `ProxyPipeline`, `UpstreamFetcher` (Tasks 10–12), `BrowserPackages`, `PackageDownloader` (Task 13).
- Produces (on `EmulatorSession`):
  - `public enum WebBrowserSetup: Equatable { case idle, downloading, needsRelaunch, installing(String), installed, failed(String) }`
  - `@Published public private(set) var webBrowserSetup: WebBrowserSetup`
  - `@Published public var simplifyPages: Bool` (persisted as `datarover.web.simplify`, default `true`)
  - `public func installWebBrowser()`

This task has no unit tests: `DataRoverShell` links the emulator core, so it is verified by building both apps and by the manual acceptance in Task 15.

- [ ] **Step 1: Start the proxy before the core**

In `EmulatorSession.swift`, add `import DataRoverWeb`. Add these properties beside `private var proxy: HTTPSProxy?`:

```swift
    private var webProxy: WebProxy?
    @Published public var simplifyPages = UserDefaults.standard.object(forKey: "datarover.web.simplify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(simplifyPages, forKey: "datarover.web.simplify") }
    }
    @Published public private(set) var webBrowserSetup: WebBrowserSetup = .idle

    public enum WebBrowserSetup: Equatable {
        case idle
        case downloading
        case needsRelaunch
        case installing(String)
        case installed
        case failed(String)
    }
```

Replace the first lines of the `Task.detached` in `init` (through `let handle = coreCreate(…)`) with:

```swift
        Task.detached(priority: .userInitiated) { [weak self] in
            // The proxy must be listening before the core opens its network,
            // because libslirp receives the port at creation.
            var webProxy: WebProxy?
            var redirectPort: UInt16 = 0
            if requestedNetwork {
                let proxy = WebProxy(pipeline: ProxyPipeline(fetcher: UpstreamFetcher(), simplify: {
                    UserDefaults.standard.object(forKey: "datarover.web.simplify") as? Bool ?? true
                }))
                if let port = try? await proxy.start() {
                    webProxy = proxy
                    redirectPort = port
                }
            }
            let handle = coreCreate(nvram: nvramDir, cfg: cfgDir, rom: romPath, networkEnabled: requestedNetwork,
                                    httpRedirectPort: redirectPort)
            await MainActor.run {
                guard let self else { webProxy?.stop(); coreDestroy(handle); return }
                self.webProxy = webProxy
```

(keep the rest of the `MainActor.run` block as it is). In `startHostBridges`, replace the `case 1:` message with:

```swift
        case 1: networkMessage = webProxy == nil
            ? "Guest Ethernet ready; the web proxy could not start"
            : "Guest Ethernet ready; web pages load through the host"
```

In `deinit`, add `webProxy?.stop()` directly after `proxy?.stop()`.

- [ ] **Step 2: Factor the package install so downloads can reuse it**

Replace `installPackage(_:)` with:

```swift
    public func installPackage(_ url: URL) {
        guard handle != nil, !installing else { return }
        let packagesDir = self.packagesDir
        Task { @MainActor [weak self] in
            let data: Data
            do {
                let stored = try PackageStaging.store(url, into: URL(fileURLWithPath: packagesDir))
                data = try Data(contentsOf: stored)
            } catch {
                self?.finishInstall(ok: false, name: url.lastPathComponent)
                return
            }
            _ = await self?.install(data, name: url.lastPathComponent)
        }
    }

    /// Sends one package over the in-process PCLink. The guest must be left
    /// running on its Storeroom computer; the call waits for it.
    @discardableResult @MainActor
    private func install(_ data: Data, name: String) async -> Bool {
        guard let handle, !installing else { return false }
        installing = true
        installProgress = 0
        // The guest speaks first, and only once its Storeroom computer is
        // opened, so say what the user has to do on the device.
        packageMessage = "Installing \(name). Open the Storeroom computer on the DataRover to start the transfer."
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let handle = self.handle else { return }
                self.installProgress = coreInstallProgress(handle)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let ok = await Task.detached(priority: .userInitiated) {
            coreInstallPackage(handle, data: data, filename: name)
        }.value
        poll.cancel()
        finishInstall(ok: ok, name: name)
        return ok
    }
```

(`install` runs on the main actor because it updates published state; only the blocking PCLink call is detached.)

- [ ] **Step 3: Add the installer flow**

Add to `EmulatorSession`:

```swift
    /// Downloads Web Browser 4.0 and its driver, turns networking on, then
    /// installs each package through the Storeroom computer.
    public func installWebBrowser() {
        guard webBrowserSetup != .downloading, !installing else { return }
        webBrowserSetup = .downloading
        let directory = URL(fileURLWithPath: packagesDir).appendingPathComponent("Web Browser")
        Task { @MainActor [weak self] in
            var files: [(BrowserPackage, URL)] = []
            for package in BrowserPackages.all {
                do {
                    files.append((package, try await PackageDownloader().ensure(package, in: directory)))
                } catch PackageDownloadError.checksumMismatch(let name) {
                    self?.webBrowserSetup = .failed("\(name) didn't match its expected checksum, so it wasn't installed.")
                    return
                } catch {
                    self?.webBrowserSetup = .failed("Couldn't download \(package.name). Check the connection and try again.")
                    return
                }
            }
            guard let self else { return }
            guard self.networkEnabled else {
                UserDefaults.standard.set(true, forKey: "datarover.network.enabled")
                self.webBrowserSetup = .needsRelaunch
                return
            }
            for (package, file) in files {
                self.webBrowserSetup = .installing(package.name)
                guard let data = try? Data(contentsOf: file), await self.install(data, name: package.name) else {
                    self.webBrowserSetup = .failed("The DataRover didn't accept \(package.name). Open the Storeroom computer and try again.")
                    return
                }
            }
            self.webBrowserSetup = .installed
        }
    }
```

- [ ] **Step 4: Add the Web browser section to the controls**

In `EmulatorControlsSheet.swift`, insert this section directly before the `Section { … } header: { Text("Bridges") }` section:

```swift
                Section {
                    Button("Install Web Browser", systemImage: "globe") {
                        session.installWebBrowser()
                        dismiss()   // the guest must run to answer the Storeroom transfer
                    }
                    .disabled(session.installing || session.webBrowserSetup == .downloading)
                    webBrowserStatus
                    Toggle("Simplify pages", isOn: $session.simplifyPages)
                    Text("Removes scripts and styles and shrinks images so modern sites fit. Turn off to see pages as sent.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Web browser")
                }
```

and add to `EmulatorControlsSheet`:

```swift
    @ViewBuilder private var webBrowserStatus: some View {
        switch session.webBrowserSetup {
        case .idle:
            Text("Downloads Web Browser 4.0, JavaScript and the Ethernet driver, then installs them.")
                .font(.footnote).foregroundStyle(.secondary)
        case .downloading:
            Text("Downloading…").font(.footnote).foregroundStyle(.secondary)
        case .needsRelaunch:
            Text("Guest networking is on. Quit and reopen DataRover, then choose Install Web Browser again.")
                .font(.footnote)
        case .installing(let name):
            Text("Installing \(name). Open the Storeroom computer on the DataRover.").font(.footnote)
        case .installed:
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed. To finish, on the DataRover:").font(.footnote)
                Text("1. Downtown, open the Internet Center and add a provider.").font(.footnote)
                Text("2. Add the EtherLink LAN connection with address 10.0.2.15.").font(.footnote)
                Text("3. On the provider’s locations tab, set home to use EtherLink LAN.").font(.footnote)
                Text("4. Open Web Browser and go to http://10.0.2.2/").font(.footnote)
            }
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }
```

- [ ] **Step 5: Build both apps and run the package tests**

Run: `swift test --package-path apple/DataRoverKit` (all suites pass).
Run: `tools/build_mac_swift_app.sh` (expected: `** BUILD SUCCEEDED **` and `staged …/build/DataRover.app`).
Run: `xcodebuild -project apple/DataRover/DataRover.xcodeproj -scheme DataRover -configuration Debug -destination 'generic/platform=iOS Simulator' ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build | tail -3` (expected: `** BUILD SUCCEEDED **`).

- [ ] **Step 6: Commit**

```bash
git add apple/DataRoverKit/Sources/DataRoverShell/EmulatorSession.swift apple/DataRoverKit/Sources/DataRoverShell/EmulatorControlsSheet.swift
# Xcode records the SwiftSoup resolution separately from SwiftPM:
git add apple/DataRover/DataRover.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null || true
git commit -m "Start the web proxy with the core and add Install Web Browser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```

---

### Task 15: Documentation and acceptance on macOS and iOS

**Files:**
- Modify: `docs/apple-bridges.md`

- [ ] **Step 1: Manual acceptance on macOS**

With a fresh app container (or after backing up `~/Library/Containers/com.example.DataRover.mac`), open `build/DataRover.app`:

1. Controls → **Install Web Browser**. Expect **needsRelaunch** text. Quit and reopen.
2. Controls → **Install Web Browser** again. Open the Storeroom computer; accept each of the three transfers.
3. Do the provider and home-location steps shown in the checklist.
4. In Web Browser, open `http://10.0.2.2/`. Expect the start page.
5. Search for `magic cap`. Expect DuckDuckGo results with working links.
6. Open `http://en.wikipedia.org/wiki/Magic_Cap`. Expect a readable page and images; then **Reader view**.
7. Open a site that serves WebP images (for example `http://www.theverge.com/`). Expect images, not broken icons.
8. Follow a link and submit a form (the search box counts).

Save a screenshot for steps 4, 5 and 6 (Magic Cap window) under `docs/images/web-proxy-*.png`.

- [ ] **Step 2: Repeat on the iOS simulator**

Build and run the `DataRover` scheme on the iOS 27 simulator and repeat steps 1–6.

- [ ] **Step 3: Document**

Add to `docs/apple-bridges.md`, after the HTTPS paragraph, a section:

```markdown
## Web Browser 4.0 and the web proxy

**Install Web Browser** in the DataRover controls downloads Web Browser 4.0,
MagicJavaScript and the EtherLink III driver from joshcarter.com, checks each
against a pinned SHA-256, turns guest networking on (relaunch once), and sends
the packages through the Storeroom computer. Nothing is bundled with the app.

The guest browser has no TLS. A pinned patch
(`apple/DataRover/scripts/patches/libslirp-http-redirect.patch`) makes
libslirp send every guest TCP connection to port 80 to a loopback proxy in the
app. The proxy fetches the page over HTTPS (plain HTTP only if TLS fails),
rewrites `https://` links, redirects and cookies for the guest, and serves
Windows-1252 text. With **Simplify pages** on, it also removes scripts, styles
and embedded media, converts images to GIF or JPEG at most 480 pixels wide,
limits pages to about 150 KB, and offers a Reader view link on every page.
`http://10.0.2.2/` is the proxy's start page with DuckDuckGo search.

Typing `https://` in Web Browser 4.0 still fails: the browser rejects the
scheme before connecting. Use `http://` for every site. The Rule 14 proxy
above remains for Web Browser 3.5.1 installed by hand.

Tests: `swift test --package-path apple/DataRoverKit` (DataRoverWebTests),
`tools/test_slirp_http_redirect.sh`, and `tools/test_core_network_options.sh`.
```

Then add the screenshots under the section.

- [ ] **Step 4: Commit**

```bash
git add docs/apple-bridges.md docs/images/web-proxy-*.png
git commit -m "Document the web proxy and browser installer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin main
```
