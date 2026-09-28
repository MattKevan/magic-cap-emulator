import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DataRoverWeb

private struct FakeFetcher: UpstreamFetching {
    var result: @Sendable (ProxyRequest) throws -> UpstreamResponse
    func fetch(_ request: ProxyRequest) async throws -> UpstreamResponse { try result(request) }
}

/// Thread-safe append-only log, for fakes that need to record what they were
/// called with (or how many times) across the pipeline's async calls.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
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

    /// A tiny, real, decodable image — opaque solid red — as PNG bytes.
    private func decodablePNG() -> Data {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

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
        let latin1 = Data("<html><body><p>caf".utf8) + Data([0xE9]) + Data("</p></body></html>".utf8)
        let untyped = await pipeline { _ in self.html("<html><body><p>x</p></body></html>", type: nil) }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(header(untyped, "Content-Type") == TextCoding.htmlContentType)
        let typed = await pipeline { _ in
            UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/html; charset=ISO-8859-1")],
                             body: latin1, url: URL(string: "https://e.com/")!)
        }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(typed.body.contains(0xE9))
        // The final body is windows-1252, so decoding it as UTF-8 (as `text()`
        // does) always turns that lone high byte into U+FFFD, even when the
        // pipeline decoded and re-encoded "café" correctly — asserting the
        // absence of U+FFFD there would contradict the assertion above on the
        // same bytes. The real failure mode this guards against is the source
        // charset being ignored: TextCoding.decode falling through to a naive
        // UTF-8 read of the ISO-8859-1 bytes, which would corrupt "é" into
        // U+FFFD *before* re-encoding and surface here as the HTML numeric
        // escape for it, since windows1252(..., html: true) escapes codepoints
        // it can't represent as a byte.
        #expect(!text(typed).contains("&#65533;"))
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

    @Test func readerViewLinksToOriginalPageWithoutMcreader() async {
        // The pageURL fed to the reader must be the URL upstream actually fetched
        // (RequestParser has already stripped mcreader=1 before this point), so
        // the "Original page" link is the plain page address, never with mcreader.
        let sentence = "Magic Cap was a pioneering operating system, with rooms, stamps, and a friendly metaphor. "
        let article = "<html><head><title>T</title></head><body><div class=\"post\">"
            + (0..<6).map { _ in "<p>\(String(repeating: sentence, count: 3))</p>" }.joined() + "</div></body></html>"
        let response = await pipeline { _ in self.html(article, url: "https://e.com/a?x=1") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/a?x=1", reader: true))
        #expect(text(response).contains("href=\"http://e.com/a?x=1\">Original page</a>"))
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
        #expect(text(forbidden).contains("http://e.com/"))
        let big = await pipeline { _ in throw UpstreamError.tooLarge }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(big.status == 502 && text(big).contains("too large"))
        #expect(text(big).contains("http://e.com/"))
        let down = await pipeline { _ in throw UpstreamError.unreachable("The server is down.") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(down.status == 502 && text(down).contains("The server is down."))
        #expect(text(down).contains("http://e.com/"))
        let insecure = await pipeline { _ in throw UpstreamError.insecure("e.com") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(insecure.status == 502 && text(insecure).contains("secure connection"))
        #expect(text(insecure).contains("http://e.com/"))
    }

    @Test func sniffsHTMLPastLeadingBOM() async {
        let body = Data([0xEF, 0xBB, 0xBF]) + Data("<html><body><p>x</p></body></html>".utf8)
        let response = await pipeline { _ in
            UpstreamResponse(status: 200, headers: [], body: body, url: URL(string: "https://e.com/")!)
        }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(header(response, "Content-Type") == TextCoding.htmlContentType)
        #expect(!text(response).contains("&#65279;"))
    }

    @Test func sniffsHTMLPastLeadingWhitespaceBeforeDoctype() async {
        let body = Data("\n  <!DOCTYPE html><html><body><p>x</p></body></html>".utf8)
        let response = await pipeline { _ in
            UpstreamResponse(status: 200, headers: [], body: body, url: URL(string: "https://e.com/")!)
        }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(header(response, "Content-Type") == TextCoding.htmlContentType)
        #expect(!text(response).contains("&#65279;"))
    }

    @Test func headFetchesUpstreamAsGETSoImagesAreRealAndCachedForLaterGETs() async {
        let recorder = Recorder()
        let png = decodablePNG()
        let proxy = pipeline { request in
            recorder.record(request.method)
            return UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "image/png")],
                                    body: png, url: URL(string: "https://e.com/a.png")!)
        }
        let head = await proxy.respond(to: ProxyRequest(method: "HEAD", host: "e.com", target: "/a.png"))
        #expect(recorder.all == ["GET"])                              // HEAD forwarded upstream as GET
        #expect(head.status == 200)
        #expect(head.body != ImageTranscoder.placeholderGIF)          // a real image, not the placeholder

        let get = await proxy.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/a.png"))
        #expect(get.body == head.body)                                // the cached real image is served to the GET
    }

    @Test func undecodableImagesAreNotCachedSoALaterDecodableFetchStillWorks() async {
        let recorder = Recorder()
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8)
        let png = decodablePNG()
        let proxy = pipeline { _ in
            recorder.record("fetch")
            if recorder.all.count == 1 {
                return UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "image/svg+xml")],
                                        body: svg, url: URL(string: "https://e.com/b.png")!)
            }
            return UpstreamResponse(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "image/png")],
                                    body: png, url: URL(string: "https://e.com/b.png")!)
        }
        let first = await proxy.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/b.png"))
        #expect(first.body == ImageTranscoder.placeholderGIF)
        let second = await proxy.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/b.png"))
        #expect(second.body != ImageTranscoder.placeholderGIF)
    }

    @Test func headResponsesKeepHeadersForSerialization() async {
        let response = await pipeline { _ in throw UpstreamError.forbidden }
            .respond(to: ProxyRequest(method: "HEAD", host: "e.com", target: "/"))
        let wire = String(decoding: response.serialized(includeBody: false), as: UTF8.self)
        #expect(wire.hasPrefix("HTTP/1.0 403"))
        #expect(wire.hasSuffix("\r\n\r\n"))
        #expect(header(response, "Content-Length") == String(response.body.count))
    }

    // MARK: - Final fix wave

    @Test func usesFixedASCIIReasonPhrases() async {
        let ok = await pipeline { _ in self.html("<p>x</p>") }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        #expect(ok.reason == "OK")
        let missing = await pipeline { _ in
            UpstreamResponse(status: 404, headers: [HTTPHeader(name: "Content-Type", value: "text/plain")],
                             body: Data("gone".utf8), url: URL(string: "https://e.com/x")!)
        }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/x"))
        #expect(missing.reason == "Not Found")
        #expect(HTTPStatus.reason(for: 308) == "Permanent Redirect")
        #expect(HTTPStatus.reason(for: 429) == "Too Many Requests")
        #expect(HTTPStatus.reason(for: 299) == "OK")
        #expect(HTTPStatus.reason(for: 599) == "Server Error")
        for status in 100...599 {
            #expect(HTTPStatus.reason(for: status).allSatisfy { $0.isASCII && !$0.isNewline }, "\(status)")
        }
    }

    @Test func keepsMetaRefreshWhenRewritingTheCharset() async {
        let page = "<html><head><meta charset=\"utf-8\"><meta http-equiv=\"content-TYPE\" content=\"text/html; charset=utf-8\">"
            + "<meta http-equiv=\"refresh\" content=\"5; url=/next\"></head><body><p>x</p></body></html>"
        let response = await pipeline { _ in self.html(page) }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        let out = text(response)
        #expect(out.contains("http-equiv=\"refresh\""))
        #expect(!out.lowercased().contains("charset=utf-8") && !out.contains("charset=\"utf-8\""))
        #expect(out.components(separatedBy: "charset=windows-1252").count == 2)
    }

    @Test func rewritesTheCharsetDeclarationWhenSimplifyIsOff() async {
        let page = "<html><head><META CHARSET=\"UTF-8\"><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
            + "<meta http-equiv=\"refresh\" content=\"5\"></head><body><p>Café</p></body></html>"
        let response = await pipeline(simplify: false) { _ in self.html(page) }
            .respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
        let out = text(response)
        #expect(!out.lowercased().contains("utf-8"))
        #expect(out.contains("charset=windows-1252"))
        #expect(out.contains("http-equiv=\"refresh\""))
        #expect(response.body.contains(0xE9))
    }

    @Test func passesNoContentAndNotModifiedThroughWithoutABody() async {
        for (status, reason) in [(204, "No Content"), (304, "Not Modified")] {
            let response = await pipeline { _ in
                UpstreamResponse(status: status, headers: [HTTPHeader(name: "Content-Type", value: "text/html"),
                                                          HTTPHeader(name: "ETag", value: "\"abc\"")],
                                 body: Data(), url: URL(string: "https://e.com/")!)
            }.respond(to: ProxyRequest(method: "GET", host: "e.com", target: "/"))
            #expect(response.status == status)
            #expect(response.reason == reason)
            #expect(response.body.isEmpty, "\(status)")
            #expect(header(response, "ETag") == "\"abc\"")
            #expect(header(response, "Content-Length") == nil, "\(status)")
        }
    }
}
