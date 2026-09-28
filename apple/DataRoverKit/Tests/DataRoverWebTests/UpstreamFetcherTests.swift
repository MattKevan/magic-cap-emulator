import Foundation
import Testing
@testable import DataRoverWeb

/// A tiny reference box for capturing a value from inside a @Sendable
/// closure without tripping mutable-capture concurrency diagnostics.
private final class Capture<Value>: @unchecked Sendable {
    var value: Value?
}

extension StubbedNetworkTests {
@Suite struct UpstreamFetcherTests {
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

    @Test func fallsBackToHTTPWhenCannotConnectToHost() async throws {
        StubURLProtocol.replies = ["https://old2.example/": .failure(.cannotConnectToHost),
                                   "http://old2.example/": .response(200, [:], Data("retro2".utf8))]
        let response = try await fetcher().fetch(ProxyRequest(method: "GET", host: "old2.example", target: "/"))
        #expect(response.url.absoluteString == "http://old2.example/")
        #expect(response.body == Data("retro2".utf8))
    }

    @Test func preservesHttpInsideRefererQueryValues() async throws {
        StubURLProtocol.replies = ["https://e.com/s?next=http://o.example/": .response(200, [:], Data())]
        let request = ProxyRequest(method: "GET", host: "e.com", target: "/s?next=http://o.example/",
                                   headers: [HTTPHeader(name: "Referer", value: "http://e.com/s?next=http://o.example/")])
        _ = try await fetcher().fetch(request)
        let sent = try #require(StubURLProtocol.seen.first)
        #expect(sent.value(forHTTPHeaderField: "Referer") == "https://e.com/s?next=http://o.example/")
    }

    @Test func fetchesHostWithPortAndPassesBareHostToPolicy() async throws {
        StubURLProtocol.seen = []
        StubURLProtocol.replies = ["https://e.com:8080/x": .response(200, [:], Data())]
        let seenHost = Capture<String>()
        let fetcher = UpstreamFetcher(configuration: StubURLProtocol.configuration(), policy: { host in
            seenHost.value = host
            return true
        })
        let response = try await fetcher.fetch(ProxyRequest(method: "GET", host: "e.com:8080", target: "/x"))
        #expect(response.url.absoluteString == "https://e.com:8080/x")
        #expect(seenHost.value == "e.com")
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
}
