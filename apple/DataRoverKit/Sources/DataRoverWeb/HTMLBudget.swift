import Foundation
import SwiftSoup

/// Keeps a document within a size budget, in document order: everything
/// from the start of the document is kept until the budget runs out, the
/// node where it runs out is descended into (or its text cut short), and
/// every node after that point, at every level, is removed. What survives
/// keeps its structure and links.
///
/// Sizes are the bytes the guest actually receives: the serialized HTML
/// (not pretty-printed) once encoded by `TextCoding.windows1252(_:html:
/// true)`, where a character outside Windows-1252 costs its whole `&#NNNN;`
/// reference. Every node's size is computed once, bottom-up, and nodes are
/// only ever removed from the end of their parent (O(1) in SwiftSoup), so
/// the whole pass is O(nodes) with no re-serialization.
enum HTMLBudget {
    /// Trims `container` so `document` fits in `budget` bytes with `reserve`
    /// bytes to spare for a notice the caller appends afterwards. Returns
    /// whether anything was removed or truncated; nothing changes, and
    /// nothing needs to be reserved, when the document already fits.
    static func fit(_ container: Element, in document: Document, budget: Int, reserve: Int) throws -> Bool {
        document.outputSettings().prettyPrint(pretty: false)
        var sizes: [ObjectIdentifier: Int] = [:]
        let total = try measure(document, into: &sizes)
        guard total > budget else { return false }
        let content = sizes[ObjectIdentifier(container), default: 0] - (try ownSize(container))
        let allowance = max(0, budget - reserve - (total - content))
        return try trim(container, to: allowance, sizes: sizes)
    }

    /// Every node's serialized size, children first, without recursion (a
    /// deeply nested page must not exhaust the stack).
    private static func measure(_ root: Node, into sizes: inout [ObjectIdentifier: Int]) throws -> Int {
        var stack: [(node: Node, expanded: Bool)] = [(root, false)]
        while let (node, expanded) = stack.popLast() {
            let children = node.getChildNodes()
            if !expanded, !children.isEmpty {
                stack.append((node, true))
                stack.append(contentsOf: children.map { ($0, false) })
                continue
            }
            var size = try ownSize(node)
            for child in children { size += sizes[ObjectIdentifier(child), default: 0] }
            sizes[ObjectIdentifier(node)] = size
        }
        return sizes[ObjectIdentifier(root), default: 0]
    }

    /// A node's size not counting its children: an element's start and end
    /// tags, a text node's escaped text, any other leaf's own markup.
    private static func ownSize(_ node: Node) throws -> Int {
        if node is Document { return 0 }
        if let element = node as? Element {
            let name = TextCoding.encodedLength(element.tagName())
            var attributes = 0
            if let list = element.getAttributes(), list.size() > 0 {
                attributes = TextCoding.encodedLength(try list.html())
            }
            if element.getChildNodes().isEmpty && element.tag().isSelfClosing() {
                return 1 + name + attributes + 3            // <name attrs />
            }
            return 1 + name + attributes + 1 + 2 + name + 1 // <name attrs></name>
        }
        if let text = node as? TextNode {
            var size = 0
            for scalar in text.getWholeText().unicodeScalars { size += textCost(scalar) }
            return size
        }
        return TextCoding.encodedLength(try node.outerHtml())
    }

    /// What one scalar of text content costs once escaped and encoded.
    private static func textCost(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x26: return 5         // &amp;
        case 0x3C, 0x3E: return 4   // &lt; &gt;
        case 0xA0: return 6         // &nbsp;
        case ..<0x80: return 1
        default: return TextCoding.encodedLength(scalar)
        }
    }

    /// Keeps `container`'s content up to `allowance` bytes, descending along
    /// the single path where the budget runs out.
    private static func trim(_ container: Element, to allowance: Int, sizes: [ObjectIdentifier: Int]) throws -> Bool {
        var element = container
        var remaining = allowance
        var changed = false
        while true {
            let children = element.getChildNodes()
            var used = 0
            var index = 0
            while index < children.count {
                let size = sizes[ObjectIdentifier(children[index]), default: 0]
                if used + size > remaining { break }
                used += size
                index += 1
            }
            guard index < children.count else { return changed }
            // Remove everything after the crossing node, last first.
            for child in children[(index + 1)...].reversed() { try child.remove() }
            changed = true
            let crossing = children[index]
            let left = remaining - used
            if let text = crossing as? TextNode {
                let kept = prefix(of: text.getWholeText(), costing: left)
                if kept.isEmpty { try text.remove() } else { text.text(kept) }
                return true
            }
            if let child = crossing as? Element {
                let own = try ownSize(child)
                if own < left {
                    element = child
                    remaining = left - own
                    continue
                }
            }
            try crossing.remove()
            return true
        }
    }

    /// The longest prefix of `text` whose escaped, encoded cost is at most
    /// `limit`, cut on a Character boundary so no character is split.
    private static func prefix(of text: String, costing limit: Int) -> String {
        var cost = 0
        var end = text.startIndex
        for index in text.indices {
            let character = text[index]
            var characterCost = 0
            for scalar in character.unicodeScalars { characterCost += textCost(scalar) }
            if cost + characterCost > limit { break }
            cost += characterCost
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
