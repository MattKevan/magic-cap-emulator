import Foundation

/// Converts upstream text to what a 1998 Latin-1 browser can display.
public enum TextCoding {
    public static let htmlContentType = "text/html; charset=windows-1252"
    public static let textContentType = "text/plain; charset=windows-1252"

    /// Windows-1252 bytes 0x80–0x9F that are printable, by Unicode scalar.
    private static let high: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
        0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
        0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
        0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    /// The single Windows-1252 byte for `scalar`, or nil when it has none.
    private static func byte(for scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        if value < 0x80 || (0xA0...0xFF).contains(value) { return UInt8(value) }
        return high[value]
    }

    /// How many bytes `scalar` takes in `windows1252(_:html: true)`: one if
    /// Windows-1252 has it, else the length of its `&#NNNN;` reference.
    static func encodedLength(_ scalar: Unicode.Scalar) -> Int {
        if byte(for: scalar) != nil { return 1 }
        var digits = 1
        var value = scalar.value
        while value >= 10 { value /= 10; digits += 1 }
        return digits + 3
    }

    /// How many bytes `text` takes once encoded by `windows1252(_:html: true)`.
    static func encodedLength(_ text: String) -> Int {
        var length = 0
        for scalar in text.unicodeScalars { length += encodedLength(scalar) }
        return length
    }

    public static func windows1252(_ text: String, html: Bool) -> Data {
        var out = Data()
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if let byte = byte(for: scalar) {
                out.append(byte)
            } else if html {
                out.append(contentsOf: Array("&#\(value);".utf8))
            } else {
                out.append(UInt8(ascii: "?"))
            }
        }
        return out
    }

    public static func decode(_ data: Data, contentType: String?) -> String {
        dropBOM(decodeRaw(data, contentType: contentType))
    }

    private static func decodeRaw(_ data: Data, contentType: String?) -> String {
        if let name = charset(in: contentType), let encoding = encoding(named: name),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        let prefix = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let range = prefix.range(of: #"charset=["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let name = prefix[range].replacingOccurrences(of: "charset=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let encoding = encoding(named: name), let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A leading U+FEFF byte-order mark survives decoding as UTF-8 (and some
    /// declared encodings) as a real character. Left in, it would reach the
    /// guest as the numeric escape `&#65279;` once re-encoded to windows-1252.
    private static func dropBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func charset(in contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("charset=") {
                return String(trimmed.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
