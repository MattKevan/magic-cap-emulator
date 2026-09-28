import Foundation
import SwiftSoup

/// A small Readability-style extractor: keep the main article only.
public enum ReaderExtractor {
    public static let minimumScore = 20.0

    private static let positive = ["article", "body", "content", "entry", "main", "page", "post", "text", "blog", "story"]
    private static let negative = ["comment", "footer", "sidebar", "promo", "related", "share", "nav", "menu",
                                   "banner", "widget", "ad-", "sponsor", "social", "subscribe"]
    private static let allowed: Set<String> = ["p", "h1", "h2", "h3", "h4", "ul", "ol", "li", "blockquote",
                                               "img", "a", "pre", "br", "em", "strong", "b", "i"]

    public static func extract(html: String, pageURL: URL, budget: Int = PageSimplifier.budget) throws -> String? {
        let document = try SwiftSoup.parse(html, pageURL.absoluteString)
        try document.select("script, style, noscript, nav, footer, aside, form, iframe, svg").remove()

        var scores: [ObjectIdentifier: (element: Element, score: Double)] = [:]
        func add(_ element: Element?, _ amount: Double) {
            guard let element else { return }
            let key = ObjectIdentifier(element)
            let base = scores[key]?.score ?? classWeight(element)
            scores[key] = (element, base + amount)
        }
        for paragraph in try document.select("p, pre, td").array() {
            let text = try paragraph.text()
            guard text.count >= 25 else { continue }
            let points = 1 + Double(text.filter { $0 == "," }.count) + min(Double(text.count) / 100, 3)
            add(paragraph.parent(), points)
            add(paragraph.parent()?.parent(), points / 2)
        }

        // Compute link density once per candidate (not per paragraph), and
        // key the result by ObjectIdentifier so the sibling pass below can
        // look a score up in O(1) instead of scanning every candidate for
        // each sibling — the latter is what made this O(children * candidates)
        // on pages with thousands of scored elements.
        var ranked: [ObjectIdentifier: (element: Element, score: Double)] = [:]
        for (key, entry) in scores {
            let density = try linkDensity(entry.element)
            ranked[key] = (entry.element, entry.score * (1 - density))
        }
        guard let (_, bestEntry) = ranked.max(by: { $0.value.score < $1.value.score }),
              bestEntry.score >= minimumScore else { return nil }
        var best = bestEntry.element
        var bestScore = bestEntry.score
        // A <section> is part of a larger article. When the best block is
        // one and its parent also scores well, the parent is the article:
        // otherwise a long page split into sections (Wikipedia) keeps only
        // its strongest sections and loses a lead whose infobox links
        // dilute its score.
        while best.tagName() == "section", let parent = best.parent(),
              let parentScore = ranked[ObjectIdentifier(parent)]?.score, parentScore >= bestScore * 0.5 {
            best = parent
            bestScore = parentScore
        }

        var kept = [best]
        if let parent = best.parent() {
            let threshold = max(10, bestScore * 0.2)
            kept = parent.children().array().filter { sibling in
                if sibling === best { return true }
                let score = ranked[ObjectIdentifier(sibling)]?.score ?? 0
                return score >= threshold
            }
        }

        let title = try document.title()
        let output = try SwiftSoup.parse("<html><head><title></title></head><body></body></html>", pageURL.absoluteString)
        try output.title(title)
        let body = output.body()!
        let original = HeaderRewriter.downgrade(pageURL.absoluteString)
        try body.append("<p><a href=\"\(original)\">Original page</a> | "
                        + "<a href=\"\(HTMLCleaning.startPageURL)\">Start page</a></p><hr>")
        if !title.isEmpty { try body.append("<h1></h1>"); try body.children().last()?.text(title) }
        for element in kept { try body.append(try element.outerHtml()) }
        // fixImages must run before clean(): it resolves the real source
        // from data-src/srcset into `src`, and clean() strips every img
        // attribute except href/src/alt — running clean() first would
        // strip data-src/srcset before fixImages ever saw them, leaving
        // lazy-loaded images as bare <img> tags or data: placeholders.
        try HTMLCleaning.fixImages(in: output)
        try clean(body)
        try HTMLCleaning.rewriteLinks(in: output, pageURL: pageURL)
        try HTMLCleaning.setCharset(output)
        try HTMLCleaning.enforce(budget: budget, on: body, in: output,
                                 notice: "<hr><p>Article shortened. <a href=\"\(original)\">Original page</a></p>")
        return try HTMLCleaning.serialize(output)
    }

    private static func classWeight(_ element: Element) -> Double {
        let names = ((try? element.className()) ?? "") + " " + element.id()
        let lower = names.lowercased()
        var weight = 0.0
        if positive.contains(where: lower.contains) { weight += 25 }
        if negative.contains(where: lower.contains) { weight -= 25 }
        return weight
    }

    private static func linkDensity(_ element: Element) throws -> Double {
        let total = try element.text().count
        guard total > 0 else { return 1 }
        let linked = try element.select("a").array().reduce(0) { $0 + (try $1.text().count) }
        return Double(linked) / Double(total)
    }

    /// Unwrap everything outside the allow-list; keep only link and image attributes.
    ///
    /// SwiftSoup's own `unwrap()`/`insertChildren` splice each moved child in
    /// one at a time at a fixed index, which is an O(childCount) array
    /// insert-and-reindex per child — O(childCount²) to unwrap a single
    /// container with thousands of children (a `<div class="post">` with
    /// 3,000 `<p>`, say), which is exactly the shape a real article page
    /// has. Rebuilding bottom-up instead — detaching each element's
    /// children once, from the end backward so every detach is O(1), then
    /// reattaching the survivors with one bulk append — keeps this O(n)
    /// over the whole subtree.
    private static func clean(_ body: Element) throws {
        let survivors = try detachAll(of: body).flatMap { try rebuild($0) }
        try body.addChildren(survivors)
    }

    /// Returns the nodes that should stand in for `node` in its parent's
    /// (rebuilt) children: `[node]` for anything but an element; for an
    /// allow-listed element, itself, with its own children rebuilt in
    /// place and its attributes pared down; for anything else, its
    /// rebuilt children directly, bubbling them up to replace it.
    private static func rebuild(_ node: Node) throws -> [Node] {
        guard let element = node as? Element else { return [node] }
        let rebuiltChildren = try detachAll(of: element).flatMap { try rebuild($0) }
        guard allowed.contains(element.tagName()) else { return rebuiltChildren }
        try element.addChildren(rebuiltChildren)
        try stripDisallowedAttributes(element)
        return [element]
    }

    /// Detaches every child of `element` and returns them, still in
    /// document order, as a plain parent-less array. Removes from the end
    /// backward: SwiftSoup's child removal is an O(childCount) array
    /// remove-and-reindex, but removing the *last* child leaves nothing
    /// after it to shift or reindex, so each detach here is O(1) and the
    /// whole pass is O(childCount) rather than O(childCount²).
    private static func detachAll(of element: Element) throws -> [Node] {
        let children = element.getChildNodes()
        for child in children.reversed() {
            try child.remove()
        }
        return children
    }

    private static func stripDisallowedAttributes(_ element: Element) throws {
        guard let attributes = element.getAttributes() else { return }
        for attribute in attributes.asList() where !["href", "src", "alt"].contains(attribute.getKey()) {
            try element.removeAttr(attribute.getKey())
        }
    }
}
