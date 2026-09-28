import Foundation
import SwiftSoup

/// Keeps a page's structure but removes what a 1998 browser cannot use.
public enum PageSimplifier {
    public static let budget = 150_000

    private static let removed = [
        "script", "noscript", "style", "link[rel~=stylesheet]", "link[rel~=preload]", "iframe", "svg",
        "video", "audio", "canvas", "source", "template", "object", "embed",
        "[hidden]", "[aria-hidden=true]", "[style*=\"display:none\"]", "[style*=\"display: none\"]",
        "img[width=1]", "img[height=1]",
        "[id*=cookie]", "[class*=cookie]", "[id*=consent]", "[class*=consent]",
    ].joined(separator: ", ")

    public static func simplify(html: String, pageURL: URL, budget: Int = PageSimplifier.budget) throws -> String {
        let document = try SwiftSoup.parse(html, pageURL.absoluteString)
        try document.select(removed).remove()
        try flattenMenus(document)
        try HTMLCleaning.fixImages(in: document)
        try HTMLCleaning.rewriteLinks(in: document, pageURL: pageURL)
        try stripPresentation(document)
        try HTMLCleaning.setCharset(document)
        let reader = HTMLCleaning.readerURL(for: pageURL)
        // Trim before adding the toolbar, so a page wrapped in one <div> is
        // trimmed inside that wrapper rather than removed whole.
        try enforce(budget: budget, on: document, reader: reader)
        try document.body()?.prepend(
            "<p><a href=\"\(reader)\">Reader view</a> | <a href=\"\(HTMLCleaning.startPageURL)\">Start page</a></p><hr>")
        return try HTMLCleaning.serialize(document)
    }

    private static func flattenMenus(_ document: Document) throws {
        for menu in try document.select("nav, header").array() {
            let links = try menu.select("a[href]").array()
            guard !links.isEmpty else { try menu.remove(); continue }
            let html = try links.map { try $0.outerHtml() }.joined(separator: " | ")
            try menu.before("<p>\(html)</p>")
            try menu.remove()
        }
    }

    private static func stripPresentation(_ document: Document) throws {
        for element in try document.getAllElements().array() {
            guard let attributes = element.getAttributes() else { continue }
            for attribute in attributes.asList() {
                let key = attribute.getKey().lowercased()
                if key == "style" || key == "class" || key.hasPrefix("on") {
                    try element.removeAttr(attribute.getKey())
                }
            }
        }
    }

    /// Drops trailing content until the page fits, descending through
    /// single-child wrappers so one outer <div> does not take everything.
    private static func enforce(budget: Int, on document: Document, reader: String) throws {
        guard let body = document.body() else { return }
        var size = try HTMLCleaning.serialize(document).utf8.count
        guard size > budget else { return }
        while size > budget {
            var container = body
            while container.children().size() == 1, let only = container.children().first() { container = only }
            guard container.children().size() > 1, let last = container.children().last() else { break }
            size -= try last.outerHtml().utf8.count
            try last.remove()
        }
        try body.append("<hr><p>Page shortened. <a href=\"\(reader)\">Reader view</a></p>")
    }
}
