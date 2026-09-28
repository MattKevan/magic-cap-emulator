import Foundation
import SwiftSoup

/// DOM helpers shared by the simplifier and the reader view.
enum HTMLCleaning {
    static let startPageURL = "http://10.0.2.2/"

    /// The attribute as an absolute http:// URL, or nil for script and empty links.
    static func downgradedAbsolute(_ element: Element, attribute: String) throws -> String? {
        let raw = try element.attr(attribute).trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw.lowercased().hasPrefix("javascript:") { return nil }
        if raw.hasPrefix("#") || raw.lowercased().hasPrefix("mailto:") { return raw }
        let absolute = try absoluteURL(element, attribute: attribute)
        return absolute.isEmpty ? nil : HeaderRewriter.downgrade(absolute)
    }

    /// SwiftSoup 2.13.9's `absUrl` does not resolve against a `<base href>`
    /// in the document head, so resolve against it manually when present.
    private static func absoluteURL(_ element: Element, attribute: String) throws -> String {
        guard let ownerDocument = element.ownerDocument(),
              let base = try ownerDocument.select("base[href]").first(),
              !(try base.attr("href").isEmpty) else {
            return try element.absUrl(attribute)
        }
        let baseHref = try base.attr("href")
        guard let baseURL = URL(string: baseHref, relativeTo: URL(string: ownerDocument.getBaseUri())) ?? URL(string: baseHref) else {
            return try element.absUrl(attribute)
        }
        let raw = try element.attr(attribute)
        guard let resolved = URL(string: raw, relativeTo: baseURL) else {
            return try element.absUrl(attribute)
        }
        return resolved.absoluteString
    }

    static func rewriteLinks(in document: Document, pageURL: URL) throws {
        for attribute in ["href", "src", "action"] {
            for element in try document.select("[\(attribute)]").array() {
                if element.tagName() == "base" { continue }
                if let url = try downgradedAbsolute(element, attribute: attribute) {
                    try element.attr(attribute, url)
                } else {
                    try element.removeAttr(attribute)
                }
            }
        }
        for form in try document.select("form:not([action])").array() {
            try form.attr("action", HeaderRewriter.downgrade(pageURL.absoluteString))
        }
        try document.select("base").remove()
    }

    /// One real source per image, sized for a 480-pixel screen. Run before
    /// `rewriteLinks` so chosen sources are resolved with the others.
    static func fixImages(in document: Document) throws {
        for image in try document.select("img").array() {
            let src = try image.attr("src")
            let lazy = try image.attr("data-src")
            if (src.isEmpty || src.hasPrefix("data:")), !lazy.isEmpty {
                try image.attr("src", lazy)
            } else if src.isEmpty, let candidate = smallestCandidate(try image.attr("srcset")) {
                try image.attr("src", candidate)
            }
            for attribute in ["srcset", "sizes", "loading", "decoding", "data-src", "data-srcset"] {
                try image.removeAttr(attribute)
            }
            if let width = Int(try image.attr("width")), width > ImageTranscoder.maxWidth {
                if let height = Int(try image.attr("height")), height > 0 {
                    try image.attr("height", String(height * ImageTranscoder.maxWidth / width))
                }
                try image.attr("width", String(ImageTranscoder.maxWidth))
            }
        }
    }

    private static func smallestCandidate(_ srcset: String) -> String? {
        srcset.split(separator: ",")
            .compactMap { entry -> (String, Int)? in
                let parts = entry.split(separator: " ", omittingEmptySubsequences: true)
                guard let url = parts.first else { return nil }
                let width = parts.dropFirst().first.flatMap { Int($0.dropLast()) } ?? Int.max
                return (String(url), width)
            }
            .min { $0.1 < $1.1 }?.0
    }

    static func setCharset(_ document: Document) throws {
        try document.select("meta[charset], meta[http-equiv]").remove()
        try document.head()?.prepend("<meta http-equiv=\"Content-Type\" content=\"\(TextCoding.htmlContentType)\">")
    }

    static func readerURL(for pageURL: URL) -> String {
        let http = HeaderRewriter.downgrade(pageURL.absoluteString)
        return http + (pageURL.query == nil ? "?" : "&") + "mcreader=1"
    }

    static func serialize(_ document: Document) throws -> String {
        document.outputSettings().prettyPrint(pretty: false)
        return try document.outerHtml()
    }
}
