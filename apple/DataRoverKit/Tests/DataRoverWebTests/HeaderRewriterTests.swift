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
