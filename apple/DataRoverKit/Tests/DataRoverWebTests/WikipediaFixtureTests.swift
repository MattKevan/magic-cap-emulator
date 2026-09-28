import Foundation
import SwiftSoup
import Testing
@testable import DataRoverWeb

/// PageSimplifier and ReaderExtractor against trimmed real Wikipedia pages
/// (see Fixtures/README.md). Wikipedia nests the whole article inside one of
/// several top-level <body> children, which is the shape that once made the
/// budget drop the article and keep only the menus.
@Suite struct WikipediaFixtureTests {
    private static let slack = 2_000

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// What the guest actually receives: the Windows-1252 bytes.
    private func sentBytes(_ html: String) -> Int {
        TextCoding.windows1252(html, html: true).count
    }

    /// The page's visible text with whitespace collapsed, so a sentence that
    /// spans links or bold runs still matches.
    private func bodyText(_ html: String) throws -> String {
        let text = try SwiftSoup.parse(html).body()?.text() ?? ""
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func simplifiedMainPageKeepsTheFeaturedArticle() throws {
        let url = URL(string: "https://en.wikipedia.org/wiki/Main_Page")!
        let out = try PageSimplifier.simplify(html: try fixture("wikipedia-Main_Page"), pageURL: url)
        #expect(try bodyText(out).contains("Genshin Impact is an action role-playing video game by miHoYo"))
        #expect(sentBytes(out) <= PageSimplifier.budget + Self.slack, "\(sentBytes(out)) bytes")
    }

    @Test func simplifiedLongArticleKeepsItsFirstParagraph() throws {
        let url = URL(string: "https://en.wikipedia.org/wiki/United_States")!
        let out = try PageSimplifier.simplify(html: try fixture("wikipedia-United_States"), pageURL: url)
        #expect(try bodyText(out).contains("is a country primarily located in North America"))
        #expect(sentBytes(out) <= PageSimplifier.budget + Self.slack, "\(sentBytes(out)) bytes")
        #expect(out.contains("Page shortened."))
        // Structure and links survive in what is kept.
        #expect(out.contains("href=\"http://en.wikipedia.org/wiki/North_America\""))
    }

    @Test func readerViewOfLongArticleKeepsItsFirstParagraphWithinBudget() throws {
        let url = URL(string: "https://en.wikipedia.org/wiki/United_States")!
        let out = try #require(try ReaderExtractor.extract(html: try fixture("wikipedia-United_States"), pageURL: url))
        #expect(try bodyText(out).contains("is a country primarily located in North America"))
        #expect(sentBytes(out) <= PageSimplifier.budget + Self.slack, "\(sentBytes(out)) bytes")
        #expect(out.contains("Article shortened."), "\(sentBytes(out)) bytes")
    }
}
