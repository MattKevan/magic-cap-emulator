# Web upgrade proxy and Web Browser 4.0 installer

## Goal

Make Magic Cap's Web Browser 4.0 load and read modern HTTPS sites in the
Apple apps (macOS and iOS), and make installing it one action.

Success: after **Install Web Browser** and the in-guest checklist, typing
`http://en.wikipedia.org` or following a link shows a readable page within the
browser's roughly 768 KB of working memory. Links, redirects, forms, cookies,
images and search work. Nothing leaves the device except the requests to the
sites themselves; no third-party rendering service is used.

## Decisions

- Browser: Web Browser 4.0 (English) with MagicJavaScript only. Web Browser
  3.5.1 remains a manual, documented install (`tools/patch_tls_browser.py`,
  Rule 14 proxy); the app does not download or patch it.
- The guest never speaks TLS. A host proxy fetches every page over HTTPS and
  presents it to the guest as plain HTTP, rewriting `https://` links.
- Traffic reaches the proxy by transparent interception in libslirp: guest
  TCP connections to port 80 are redirected to the proxy on host loopback.
  No browser setting or patch is needed.
- Pages are simplified by default, with a per-page reader view.
- Text is served as Windows-1252. Japanese is out of scope.
- The proxy is Swift inside `DataRoverShell`, so it runs on iOS. HTML parsing
  uses SwiftSoup (Swift Package, MIT), the package's first third-party
  dependency.

Out of scope: automating the Storeroom-computer tap or the provider/location
setup; Shortcuts actions; typed `https://` URLs in 4.0 (it rejects the scheme
before connecting); the Japanese browser; changing the existing Rule 14
`HTTPSProxy`.

## Request flow

1. The guest browser resolves the site through slirp's DNS (10.0.2.3, the host
   resolver) as usual and connects to its address on TCP port 80.
2. The patched libslirp redirects the connection to `127.0.0.1:<proxy port>`.
3. The proxy reads one HTTP/1.0 request. The site comes from the `Host:` header
   (4.0 sends it). The proxy removes its own `mcreader=1` query parameter.
4. `UpstreamFetcher` requests `https://<host><path>`. If the TLS connection
   fails (not an HTTP error status), it retries once over `http://`.
5. The response is transformed by content type (below) and returned as
   HTTP/1.0 with `Connection: close`.
6. `http://10.0.2.2/` is also redirected to the proxy and serves the start
   page.

## libslirp change

`apple/DataRover/scripts/build-network-deps.sh` applies a pinned patch file,
`apple/DataRover/scripts/patches/libslirp-http-redirect.patch`, to libslirp
4.9.5 before building. The patch adds:

```c
/* Redirect guest TCP connections to port 80 to host 127.0.0.1:port.
 * 0 disables. Connections to other ports are unchanged. */
void slirp_set_http_redirect_port(Slirp *slirp, uint16_t port);
```

The redirect is applied in the outbound TCP connect translation
(`sotranslate_out4`, beside the existing 10.0.2.2-to-loopback mapping) and
covers any destination address on port 80, including `10.0.2.2:80`. The
script verifies the patched source tree before building and fails if the
patch does not apply cleanly.

Core plumbing:

- `datarover_create_options` gains `uint16_t http_redirect_port` (appended;
  `struct_size` keeps older callers valid; 0 means off).
- The core passes it to the slirp network module, which calls
  `slirp_set_http_redirect_port` after `slirp_new`. MAME's standalone and CLI
  builds are unaffected (they never set it).
- `CoreBridge.h` and `CoreHandle.swift` mirror the new field.

## Components

All new Swift code lives in `apple/DataRoverKit/Sources/DataRoverShell/WebProxy/`.

- **`DestinationPolicy`**: the existing `isForbiddenHost` and
  `resolvesOnlyPublicAddresses` checks, moved out of `HTTPSProxy.swift`
  unchanged so both proxies share one tested copy. `HTTPSProxy` calls it.
- **`ProxyListener`**: `NWListener` on 127.0.0.1, system-chosen port reported
  to the session. One request per connection; limits of 16 KB headers, 2 MB
  body, 8 concurrent connections (503 beyond), 30 s per connection. Accepts
  GET, HEAD and POST in origin or absolute form. Produces a `ProxyRequest`
  (method, host, path and query, headers, body, reader flag).
- **`UpstreamFetcher`**: `URLSession` with an ephemeral configuration, no
  cookie storage, no URL cache, redirects not followed. Sends the guest's
  `Cookie`, form body and `Referer` (scheme corrected to `https`). Uses a
  current Safari user-agent. Response cap 8 MB before transformation (502
  beyond). Checks `DestinationPolicy` before each fetch.
- **Header rewriting**: `Location` and `Content-Location` `https://` to
  `http://`; `Set-Cookie` loses `Secure` and `SameSite`; `Strict-Transport-
  Security`, `Content-Security-Policy`, `Content-Encoding` and
  `Transfer-Encoding` are dropped; `Content-Length` is recomputed.
- **`PageSimplifier`** (HTML, SwiftSoup), used unless reader view is requested:
  - removes `script`, `noscript`, `style`, stylesheet `link`, `iframe`, `svg`,
    `video`, `audio`, `canvas`, `source`, `template`, hidden elements
    (`hidden`, `aria-hidden="true"`, inline `display:none`), 1×1 images and
    elements whose class or id marks a cookie banner;
  - resolves relative URLs and rewrites `https://` to `http://` in `href`,
    `src` and `action`;
  - picks one image source from `srcset` or `data-src`, and caps image
    `width`/`height` to 480 wide, preserving aspect ratio;
  - unwraps `nav` and `header` menus into a plain list of links;
  - removes all `style`, `class` and event-handler attributes;
  - prepends a bar with **Reader view** (same URL with `mcreader=1`) and
    **Start page** links;
  - enforces a budget of about 150 KB of output HTML by dropping trailing
    top-level elements, then appends a "Page shortened. Reader view" link.
- **`ReaderExtractor`**: a Readability-style scorer. Candidate blocks are
  scored by text length, paragraph and comma counts and link density, with
  penalties for class/id names such as `comment`, `footer`, `sidebar`,
  `promo`, `related` and `share`. It keeps the best block and strong siblings
  and emits the page title and clean `p`, `h1`–`h4`, `ul`/`ol`/`li`,
  `blockquote`, `img` and `a`, with an **Original page** link at the top. If no
  candidate clears a minimum score, it falls back to `PageSimplifier`.
- **`ImageTranscoder`**: decodes anything ImageIO supports (including WebP,
  AVIF, HEIC and PNG), scales to at most 480 px wide, flattens transparency
  onto white, and outputs JPEG at quality 0.6, or GIF when the source has
  transparency or at most 256 colours. SVG and undecodable images return a
  small placeholder GIF. An in-memory LRU cache of 4 MB keyed by URL.
- **CSS, JavaScript and web fonts**: answered with an empty `200` of the same
  type. Other content types pass through unchanged within the 8 MB cap.
- **`TextEncoder`**: HTML and plain text are encoded as Windows-1252; code
  points outside it become numeric character references. The `Content-Type`
  charset and any `<meta charset>` are rewritten to match.
- **`StartPage`**: served for `10.0.2.2`. A search form, a few links
  (Wikipedia, 68k.news, text-only news), and a line on reader view. Search
  submits to `html.duckduckgo.com/html/`, whose results go through the
  simplifier like any page.
- **Error pages**: DNS failure, TLS-then-HTTP failure, policy rejection,
  timeouts and caps produce a short HTML page naming the problem and the URL,
  never a dropped connection.
- **`WebProxy`**: owns the listener and pipeline; `start()` returns the port,
  `stop()` closes all connections. `EmulatorSession` starts it with the other
  host bridges, before the core is created, and passes the port through
  `datarover_create_options`. A **Simplify pages** setting (UserDefaults,
  default on) disables `PageSimplifier`, `ReaderExtractor` and
  `ImageTranscoder` while keeping the HTTPS upgrade and link rewriting.

## Installer

`BrowserInstaller` (in `DataRoverShell`) downloads into the app's
`Documents/packages` directory and verifies each file before use:

| Package | Source | Size | SHA-256 |
|---|---|---|---|
| `EtherLinkIII.pkg` | `https://joshcarter.com/magic_cap/packages/EtherLinkIII.pkg` | 65,624 | `c0b23f24a91e7b03f4adf1a356dc4356f4091284a424119bbdd9d89f72279b34` |
| `WebBrowser40.mc2` | `https://joshcarter.com/magic_cap/packages/WebBrowser40.mc2` | 508,892 | `b401b0f82beff0d945a4eb0361c8cf02aa16ec3fd79a3267edd46248c92bc706` |
| `MagicJavaScript.pkg` | `https://joshcarter.com/magic_cap/packages/MagicJavaScript.pkg` | 467,876 | `beb0de0cdb51207534c280c88402ec11972dd7dfce11cd08514adc92c2f6f406` |

Nothing is bundled with the app. A checksum mismatch deletes the file and
fails that step. Files that already verify are not downloaded again.

The controls sheet gains a **Web browser** section with **Install Web
Browser**. The flow:

1. Download and verify the three packages.
2. Turn on guest networking if it is off, and ask the user to relaunch.
3. Queue the driver, browser and JavaScript packages on the existing
   in-process PCLink install, in that order.
4. Show a checklist with a status per step (done, waiting, failed with a
   reason, retry): download; networking; tap the Storeroom computer to
   install (repeated per package if the link closes between packages); set
   up the EtherLink provider (connection **EtherLink LAN**, address
   `10.0.2.15`, **home** location mapped to it); open the browser at
   `http://10.0.2.2/`.

The in-guest steps are instructions, not automation. The **Simplify pages**
toggle sits in the same section.

## Testing

Swift unit tests in `DataRoverKitTests` (no network access):

- `ProxyListener` request parsing: origin and absolute forms, header and body
  limits, `Host` handling, `mcreader` stripping.
- `DestinationPolicy`: the current rules, including numeric host encodings.
- Header rewriting, including cookies and redirects.
- `PageSimplifier` and `ReaderExtractor` against saved fixture pages (a
  Wikipedia article, a news homepage, a blog post, DuckDuckGo HTML results):
  removed elements, rewritten links, the size budget, reader fallback.
- `ImageTranscoder` with WebP, PNG with alpha, AVIF and SVG inputs: output
  format and dimensions.
- `TextEncoder` with characters inside and outside Windows-1252.
- `UpstreamFetcher` against a `URLProtocol` stub: TLS failure fallback,
  redirects not followed, cookies passed through, size cap.
- `BrowserInstaller` checksum handling with fixture bytes.

Core: a test in `mame/src/libdatarover/tests` that exercises the patched
translation with a stub listener as the redirect target, proving a port-80
connection arrives there and other ports and `10.0.2.2:8765` are unchanged.
If driving it from the guest is impractical, it calls the patched libslirp
directly with a synthetic SYN through `slirp_input`.

Manual acceptance on macOS and iOS: install through the new flow; load the
start page, a DuckDuckGo search, a Wikipedia article in simplified and reader
view, and a page with WebP images; follow a link and submit a form. Record
screenshots in `docs/apple-bridges.md`.

## Risks

- **Browser memory.** 4.0 may still fail on large pages within 768 KB. The
  150 KB budget is a starting point, tuned during acceptance.
- **Site blocking.** Some sites block non-browser clients or require
  JavaScript; those show the site's own page or an error, not a fix.
- **Plaintext hop.** Guest-to-proxy traffic is unencrypted but never leaves
  the process: slirp and the proxy share the app.
- **libslirp patch upkeep.** Upgrading libslirp means re-applying one small
  patch; the build fails loudly if it no longer applies.
