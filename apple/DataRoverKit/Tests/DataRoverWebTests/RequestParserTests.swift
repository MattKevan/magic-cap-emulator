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
