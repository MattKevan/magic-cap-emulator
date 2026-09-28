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
        let requestURL = "http://\(request.host)\(request.target)"
        if request.host == StartPage.host {
            guard request.target == "/" || request.target.hasPrefix("/?") else {
                return Self.errorPage(status: 404, reason: "Not Found", title: "Page not found",
                                      detail: "The start page is at http://10.0.2.2/.", url: requestURL)
            }
            return Self.text(status: 200, reason: "OK", headers: [], html: StartPage.html())
        }
        // A guest HEAD is fetched upstream as GET: fetching HEAD itself would
        // get an empty image body back, transcoding it to the 1x1 placeholder
        // — the listener (Task 12) drops the body for HEAD, so Content-Length
        // still matches what a GET would have sent.
        var upstreamRequest = request
        if upstreamRequest.method == "HEAD" { upstreamRequest.method = "GET" }
        do {
            return try transform(await fetcher.fetch(upstreamRequest), reader: request.reader)
        } catch UpstreamError.forbidden {
            return Self.errorPage(status: 403, reason: "Forbidden", title: "That address isn't allowed",
                                  detail: "The proxy only visits public websites.", url: requestURL)
        } catch UpstreamError.tooLarge {
            return Self.errorPage(status: 502, reason: "Bad Gateway", title: "Page too large",
                                  detail: "The page is too large to load.", url: requestURL)
        } catch UpstreamError.unreachable(let message) {
            return Self.errorPage(status: 502, reason: "Bad Gateway", title: "Couldn't load the page",
                                  detail: message, url: requestURL)
        } catch {
            return Self.errorPage(status: 502, reason: "Bad Gateway", title: "Couldn't load the page",
                                  detail: error.localizedDescription, url: requestURL)
        }
    }

    private func transform(_ upstream: UpstreamResponse, reader: Bool) throws -> ProxyResponse {
        let headers = HeaderRewriter.rewrite(upstream.headers).filter { $0.name.lowercased() != "content-type" }
        let contentType = upstream.headers.first { $0.name.lowercased() == "content-type" }?.value
        let mime = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? (Self.looksLikeHTML(upstream.body) ? "text/html" : "application/octet-stream")
        let reason = HTTPStatus.reason(for: upstream.status)
        let enabled = simplify()

        // No Content and Not Modified never carry a body: pass the headers
        // through as they are rather than generating one.
        if upstream.status == 204 || upstream.status == 304 {
            return ProxyResponse(status: upstream.status, reason: reason,
                                 headers: HeaderRewriter.rewrite(upstream.headers) + [HTTPHeader(name: "Connection", value: "close")],
                                 body: Data())
        }

        switch mime {
        case "text/html", "application/xhtml+xml":
            let source = TextCoding.decode(upstream.body, contentType: contentType)
            let page: String
            if !enabled {
                page = HTMLCleaning.setCharset(in: HeaderRewriter.downgrade(source))
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
                // An undecodable source (or an empty HEAD body, now moot since
                // HEAD is fetched as GET) transcodes to the shared placeholder;
                // never cache that under a real image's URL, or a later fetch
                // that *would* decode fine is masked by the cached placeholder.
                if fresh.data != ImageTranscoder.placeholderGIF {
                    images.store(fresh, for: key)
                }
                return fresh
            }()
            return Self.framed(status: 200, reason: "OK", headers: headers, contentType: image.contentType, body: image.data)
        default:
            return Self.framed(status: upstream.status, reason: reason, headers: headers,
                               contentType: contentType ?? mime, body: upstream.body)
        }
    }

    public static func errorPage(status: Int, reason: String, title: String, detail: String, url: String? = nil) -> ProxyResponse {
        let urlParagraph = url.map { "<p>\(escape($0))</p>" } ?? ""
        return text(status: status, reason: reason, headers: [],
             html: "<html><head><title>\(escape(title))</title></head><body><h1>\(escape(title))</h1>"
                 + "<p>\(escape(detail))</p>" + urlParagraph
                 + "<p><a href=\"http://10.0.2.2/\">Start page</a></p></body></html>")
    }

    /// Whether an untyped body looks like HTML: a leading UTF-8 BOM and any
    /// ASCII whitespace (both common before `<!DOCTYPE …>` or `<html>`) are
    /// skipped before testing for the opening `<`.
    private static func looksLikeHTML(_ body: Data) -> Bool {
        var bytes = body[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0D || first == 0x0A {
            bytes = bytes.dropFirst()
        }
        return bytes.first == UInt8(ascii: "<")
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
