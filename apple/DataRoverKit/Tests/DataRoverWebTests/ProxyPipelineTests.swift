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
