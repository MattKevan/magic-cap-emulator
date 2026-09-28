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
