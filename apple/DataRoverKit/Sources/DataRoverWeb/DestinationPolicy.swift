import Darwin
import Foundation

/// Which upstream hosts the host proxies may contact: public Internet only.
public enum DestinationPolicy {
    public static func allows(_ host: String) -> Bool {
        !isForbiddenHost(host) && resolvesOnlyPublicAddresses(host)
    }

    public static func isForbiddenHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") { return true }
        let pieces = lower.split(separator: ".").compactMap { UInt8($0) }
        if pieces.count == 4 {
            let b = pieces
            return b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 169 && b[1] == 254)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 192 && b[1] == 0)
                || (b[0] == 198 && (18...19).contains(b[1])) || (b[0] == 240)
        }
        // Literal IPv6 is not needed by the legacy browser proxy. Reject all
        // IPv6 literals rather than risk accepting an unusual local range.
        if lower.contains(":") { return true }
        return false
    }

    public static func resolvesOnlyPublicAddresses(_ host: String) -> Bool {
        // Reject alternate integer/hex encodings of IPv4 addresses before DNS.
        if host.range(of: #"^[0-9a-fA-FxX.]+$"#, options: .regularExpression) != nil,
           host.contains(where: { $0.isNumber }) { return false }
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?
        let resolution = host.withCString { getaddrinfo($0, nil, &hints, &head) }
        guard resolution == 0, let first = head else { return false }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let item = current {
            let entry = item.pointee
            if let address = entry.ai_addr {
                if entry.ai_family == AF_INET {
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    let octets = withUnsafeBytes(of: ipv4) { Array($0) }
                    if octets.count == 4 {
                        found = true
                        let ip = octets.map(Int.init)
                        if ip[0] == 0 || ip[0] == 10 || ip[0] == 127 || ip[0] >= 224
                            || (ip[0] == 169 && ip[1] == 254) || (ip[0] == 172 && (16...31).contains(ip[1]))
                            || (ip[0] == 192 && (ip[1] == 168 || ip[1] == 0))
                            || (ip[0] == 100 && (64...127).contains(ip[1]))
                            || (ip[0] == 198 && (18...19).contains(ip[1])) || ip[0] == 240 { return false }
                    }
                } else if entry.ai_family == AF_INET6 {
                    let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                    if bytes.count == 16 {
                        found = true
                        let unspecified = bytes.allSatisfy { $0 == 0 }
                        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                        let mappedV4 = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
                        if unspecified || loopback || bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc
                            || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || mappedV4 { return false }
                    }
                }
            }
            current = entry.ai_next
        }
        return found
    }
}
