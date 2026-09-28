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
    private static let cookieContainers = ["div", "aside", "section", "dialog", "form"]
    private static let cookieAttributes = ["id*=cookie", "class*=cookie", "id*=consent", "class*=consent"]

    private static let removed = ([
        "script", "noscript", "style", "link[rel~=stylesheet]", "link[rel~=preload]", "iframe", "svg",
        "video", "audio", "canvas", "source", "template", "object", "embed",
        "[hidden]", "[aria-hidden=true]", "[style*=\"display:none\"]", "[style*=\"display: none\"]",
        "img[width=1]", "img[height=1]",
    ] + cookieContainers.flatMap { tag in cookieAttributes.map { "\(tag)[\($0)]" } }).joined(separator: ", ")

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
        return try !header.select("ul a[href], ol a[href]").isEmpty()
    }

    private static func flattenAsMenu(_ menu: Element) throws {
        let links = try menu.select("a[href]").array()
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
                if key == "style" || key == "class" || key.hasPrefix("on") {
                    try element.removeAttr(attribute.getKey())
                }
            }
        }
    }

    /// Drops trailing content until the page fits, descending through
    /// single-child wrappers so one outer <div> does not take everything.
    /// Stops descending at a container whose own direct text dominates its
    /// size — going past it (e.g. into a trailing empty `<span>`) would
    /// leave the huge text behind and achieve nothing — and truncates that
    /// container's text instead. Only appends the notice if something was
    /// actually removed or truncated, never on an unproductive pass.
    ///
    /// Each container's children and text-heaviness are read exactly once
    /// here (not once per element removed): re-fetching `children()` and
    /// re-serializing a container's whole, still-mostly-full subtree on
    /// every single removal is what made an earlier version of this pass
    /// quadratic on pages with thousands of elements.
    private static func enforce(budget: Int, on document: Document, reader: String) throws {
        guard let body = document.body() else { return }
        var size = try HTMLCleaning.serialize(document).utf8.count
        guard size > budget else { return }
        let notice = "<hr><p>Page shortened. <a href=\"\(reader)\">Reader view</a></p>"
        var changed = false

        var container = body
        var kids = container.children().array()
        while kids.count == 1, let only = kids.first, !isTextHeavy(container) {
            container = only
            kids = container.children().array()
        }

        if size > budget, kids.count > 1 {
            // Every child's serialized size is computed once, then trailing
            // children are dropped one at a time by subtracting from that
            // precomputed total. SwiftSoup's removal of the *last* child is
            // O(1) (there are no later siblings to reindex), so this whole
            // pass is O(children), not O(children²).
            var sizes = try kids.map { try $0.outerHtml().utf8.count }
            while size > budget, kids.count > 1 {
                size -= sizes.removeLast()
                try kids.removeLast().remove()
                changed = true
            }
        }

        if size > budget, try truncate(container, budget: budget, currentSize: size, notice: notice) {
            changed = true
        }

        guard changed else { return }
        try body.append(notice)
    }

    /// True when an element's own direct text (not counting child elements)
    /// makes up most of its rendered size, so descending into a child of
    /// its would strand that text instead of shrinking anything.
    private static func isTextHeavy(_ element: Element) -> Bool {
        let ownText = element.ownText()
        guard !ownText.isEmpty else { return false }
        let total = (try? element.outerHtml().utf8.count) ?? ownText.utf8.count
        return ownText.utf8.count * 2 >= total
    }

    /// Last resort when there is nothing left to remove: replace the
    /// container's content with a truncated plain-text version, leaving
    /// room for `notice` to still fit within budget. Returns whether it
    /// actually shortened anything.
    ///
    /// HTML-escaping (`&` -> `&amp;`, `<` -> `&lt;`, …) can inflate the
    /// serialized size well past the plain-text byte count used to pick the
    /// initial cut, so the actual serialized size is checked and the cut
    /// shrunk proportionally until it fits — a handful of iterations always
    /// suffices, since escaping expands a character by at most 5x.
    private static func truncate(_ container: Element, budget: Int, currentSize: Int, notice: String) throws -> Bool {
        let overhead = currentSize - (try container.outerHtml().utf8.count)
        let allowedForContainer = max(0, budget - overhead - notice.utf8.count)
        let text = try container.text()
        guard text.utf8.count > allowedForContainer else { return false }

        var allowance = allowedForContainer
        for _ in 0..<6 {
            let candidate = safePrefix(of: text, maxBytes: allowance)
            try container.text(candidate)
            let containerBytes = try container.outerHtml().utf8.count
            if containerBytes <= allowedForContainer || candidate.isEmpty { break }
            let ratio = Double(allowedForContainer) / Double(containerBytes)
            allowance = max(0, Int(Double(allowance) * ratio) - 1)
        }
        return true
    }

    /// The longest prefix of `text` whose UTF-8 encoding is at most
    /// `maxBytes`, cut on a Character boundary so a multi-byte character is
    /// never split (which would otherwise decode as U+FFFD).
    private static func safePrefix(of text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var result = ""
        for character in text {
            let charBytes = String(character).utf8.count
            if bytes + charBytes > maxBytes { break }
            bytes += charBytes
            result.append(character)
        }
        return result
    }
}
