import Foundation
import SwiftSoup

/// Keeps a page's structure but removes what a 1998 browser cannot use.
public enum PageSimplifier {
    public static let budget = 150_000

    /// Cookie/consent banners are usually a div/aside/section/dialog/form, not
    /// the whole page: an unqualified `[id*=cookie]` also matches `<body
    /// class="has-cookie-banner">`, deleting the entire page. Restrict the
    /// match to the container tags a banner is actually built from, and never
    /// to html, head, body, main or article.
    private static let cookieContainers: Set<String> = ["div", "aside", "section", "dialog", "form"]
    private static let cookieMarkers = ["cookie", "consent"]

    private static let removedTags = [
        "script", "noscript", "style", "iframe", "svg", "video", "audio", "canvas", "source", "template",
        "object", "embed",
    ].joined(separator: ", ")

    public static func simplify(html: String, pageURL: URL, budget: Int = PageSimplifier.budget) throws -> String {
        let document = try SwiftSoup.parse(html, pageURL.absoluteString)
        try removeHeavyAndHidden(document)
        try flattenMenus(document)
        try HTMLCleaning.fixImages(in: document)
        try HTMLCleaning.rewriteLinks(in: document, pageURL: pageURL)
        try stripPresentation(document)
        try HTMLCleaning.setCharset(document)
        let reader = HTMLCleaning.readerURL(for: pageURL)
        guard let body = document.body() else { return try HTMLCleaning.serialize(document) }
        try body.prepend(
            "<p><a href=\"\(reader)\">Reader view</a> | <a href=\"\(HTMLCleaning.startPageURL)\">Start page</a></p><hr>")
        try HTMLCleaning.enforce(budget: budget, on: body, in: document,
                                 notice: "<hr><p>Page shortened. <a href=\"\(reader)\">Reader view</a></p>")
        return try HTMLCleaning.serialize(document)
    }

    /// Removes heavy elements (by tag) and hidden ones, stylesheet links,
    /// 1x1 images and cookie banners (by attribute). The attribute tests are
    /// one pass in Swift rather than CSS attribute selectors: SwiftSoup
    /// answers those from an index of every distinct attribute value, whose
    /// build is superlinear in their number (minutes on a Wikipedia article
    /// with thousands of reference links).
    private static func removeHeavyAndHidden(_ document: Document) throws {
        try document.select(removedTags).remove()
        let doomed = try document.getAllElements().array().filter(isHiddenOrUnwanted)
        for element in doomed.reversed() { try element.remove() }
    }

    private static func isHiddenOrUnwanted(_ element: Element) throws -> Bool {
        func value(_ name: String) throws -> String {
            try element.attr(name).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let tag = element.tagName()
        if tag == "link" {
            let rel = try value("rel")
            if rel.contains("stylesheet") || rel.contains("preload") { return true }
        }
        if element.hasAttr("hidden") { return true }
        let ariaHidden = try value("aria-hidden")
        if ariaHidden == "true" { return true }
        let style = try value("style")
        if style.contains("display:none") || style.contains("display: none") { return true }
        if tag == "img" {
            let width = try value("width"), height = try value("height")
            if width == "1" || height == "1" { return true }
        }
        if cookieContainers.contains(tag) {
            let names = try value("id") + " " + value("class")
            if cookieMarkers.contains(where: names.contains) { return true }
        }
        return false
    }

    /// Every <nav> is a menu. A <header> is only a menu when it actually
    /// holds one (a nested <nav>, or a list of links) — otherwise it is
    /// page content (a masthead with a headline, say) and is unwrapped in
    /// place rather than discarded.
    private static func flattenMenus(_ document: Document) throws {
        for header in try document.select("header").array() {
            if try isMenuHeader(header) {
                try flattenAsMenu(header)
            } else {
                try header.unwrap()
            }
        }
        for nav in try document.select("nav").array() {
            try flattenAsMenu(nav)
        }
    }

    private static func isMenuHeader(_ header: Element) throws -> Bool {
        if try !header.select("nav").isEmpty() { return true }
        return try header.select("ul a, ol a").array().contains { $0.hasAttr("href") }
    }

    private static func flattenAsMenu(_ menu: Element) throws {
        let links = try menu.getElementsByTag("a").array().filter { $0.hasAttr("href") }
        guard !links.isEmpty else { try menu.remove(); return }
        let html = try links.map { try $0.outerHtml() }.joined(separator: " | ")
        try menu.before("<p>\(html)</p>")
        try menu.remove()
    }

    private static func stripPresentation(_ document: Document) throws {
        for element in try document.getAllElements().array() {
            guard let attributes = element.getAttributes() else { continue }
            for attribute in attributes.asList() {
                let key = attribute.getKey().lowercased()
                if key == "style" || key == "class" || key.hasPrefix("on") || key.hasPrefix("data-") {
                    try element.removeAttr(attribute.getKey())
                }
            }
        }
    }
}
