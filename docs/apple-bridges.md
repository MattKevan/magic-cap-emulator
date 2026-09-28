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

## Web Browser 4.0 and the web proxy

**Install Web Browser** in the DataRover controls (the General Magic logo; on
the Mac also File > Install Web Browser…) downloads Web Browser 4.0,
MagicJavaScript and the EtherLink III driver from joshcarter.com, checks each
against a pinned SHA-256, turns guest networking on (relaunch once), and sends
the packages through the Storeroom computer. Nothing is bundled with the app.

The guest browser has no TLS. A pinned patch
(`apple/DataRover/scripts/patches/libslirp-http-redirect.patch`) makes
libslirp send every guest TCP connection to port 80 to a loopback proxy in the
app. The proxy fetches the page over HTTPS. It retries over plain HTTP only
when HTTPS cannot connect at all (connection refused or timed out), and never
for a host that has already answered over HTTPS in this session. A certificate
or TLS handshake failure shows an error page instead, because anyone on the
network can cause one and a plaintext retry would expose the guest's cookies
and form data. The proxy then rewrites `https://` links, redirects and cookies for the guest, and serves
Windows-1252 text. With **Simplify pages** on, it also removes scripts, styles
and embedded media, converts images to GIF or JPEG at most 480 pixels wide,
limits pages to about 150 KB, and offers a Reader view link on every page.
`http://10.0.2.2/` is the proxy's start page with DuckDuckGo search.

Typing `https://` in Web Browser 4.0 still fails: the browser rejects the
scheme before connecting. Use `http://` for every site. The Rule 14 proxy
above remains for Web Browser 3.5.1 installed by hand.

Tests: `swift test --package-path apple/DataRoverKit` (DataRoverWebTests),
`tools/test_slirp_http_redirect.sh`, and `tools/test_core_network_options.sh`.

### Checking it in the guest

1. Controls, **Install Web Browser**. It reports that a relaunch is needed;
   quit and reopen the app.
2. **Install Web Browser** again, open the Storeroom computer and accept each
   of the three transfers.
3. Do the EtherLink provider and home-location steps shown in the checklist.
4. In Web Browser, open `http://10.0.2.2/`. The start page should appear.
5. Search for `magic cap`. DuckDuckGo results should appear with working links.
6. Open `http://en.wikipedia.org/wiki/Magic_Cap`. The page should be readable
   with images; then follow **Reader view**.
7. Open a site that serves WebP images, for example `http://www.theverge.com/`.
   Images should appear, not broken icons.
8. Follow a link and submit a form (the search box counts).

The proxy was also exercised without the guest, by sending HTTP/1.0 requests
(old-browser headers) straight to the running proxy on loopback. The start
page, DuckDuckGo search, Wikipedia (plain and reader view, with a thumbnail
served as `image/gif`) and The Verge front page all returned 200 within the
size limit. Some `https://` strings remain in non-navigational places such as
metadata attributes, inline JSON and visible page text. This does not replace
the in-guest check above.

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
