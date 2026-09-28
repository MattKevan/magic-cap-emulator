import Foundation

/// Adapts upstream HTTPS response headers for a guest that only sees HTTP.
public enum HeaderRewriter {
    private static let dropped: Set<String> = [
        "strict-transport-security", "content-security-policy", "content-security-policy-report-only",
        "content-encoding", "transfer-encoding", "content-length", "connection", "keep-alive", "alt-svc",
    ]

    public static func downgrade(_ text: String) -> String {
        text.replacingOccurrences(of: "https://", with: "http://", options: .caseInsensitive)
    }

    public static func rewrite(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        var out: [HTTPHeader] = []
        for header in headers {
            let lower = header.name.lowercased()
            if dropped.contains(lower) { continue }
            switch lower {
            case "location", "content-location":
                out.append(HTTPHeader(name: header.name, value: downgrade(header.value)))
            case "set-cookie":
                for cookie in splitSetCookie(header.value) {
                    out.append(HTTPHeader(name: header.name, value: stripCookieSecurity(cookie)))
                }
            default:
                out.append(header)
            }
        }
        return out
    }

    /// URLSession joins repeated Set-Cookie headers with ", ". Split only at a
    /// comma followed by a new `name=`, so Expires dates stay intact.
    public static func splitSetCookie(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #",\s*(?=[^;,=\s]+=)"#)
        let range = NSRange(value.startIndex..., in: value)
        var pieces: [String] = []
        var start = value.startIndex
        for match in pattern.matches(in: value, range: range) {
            guard let r = Range(match.range, in: value) else { continue }
            let piece = value[start..<r.lowerBound]
            pieces.append(piece.trimmingCharacters(in: .whitespaces))
            start = r.upperBound
        }
        pieces.append(value[start...].trimmingCharacters(in: .whitespaces))
        return pieces.filter { !$0.isEmpty }
    }

    private static func stripCookieSecurity(_ cookie: String) -> String {
        cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { attribute in
                let name = attribute.split(separator: "=").first.map { $0.lowercased() } ?? ""
                return name != "secure" && name != "samesite"
            }
            .joined(separator: "; ")
    }
}
