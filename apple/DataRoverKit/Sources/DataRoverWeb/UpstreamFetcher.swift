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
                policy: @escaping @Sendable (String) -> Bool = { DestinationPolicy.allows($0) }) {
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
