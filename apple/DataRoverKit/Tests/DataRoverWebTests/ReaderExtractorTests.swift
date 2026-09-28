import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct ReaderExtractorTests {
    private let page = URL(string: "https://blog.example/post?id=4")!
    private let sentence = "Magic Cap was a pioneering operating system, with rooms, stamps, and a friendly metaphor. "

    @Test func keepsTheArticleAndDropsTheChrome() throws {
        let article = (0..<6).map { "<p>\($0) \(String(repeating: sentence, count: 3))</p>" }.joined()
        let html = """
        <html><head><title>A history</title></head><body>
        <div class="sidebar"><a href="/1">One</a> <a href="/2">Two</a> <a href="/3">Three</a></div>
        <div class="post-content"><h2>Origins</h2>\(article)<img src="/fig.png" alt="Figure"></div>
        <div class="comments"><p>\(sentence)</p></div>
        <footer>© Example</footer></body></html>
        """
        let out = try #require(try ReaderExtractor.extract(html: html, pageURL: page))
        #expect(out.contains("<h1>A history</h1>"))
        #expect(out.contains("Origins"))
        #expect(out.contains("5 Magic Cap"))
        #expect(out.contains("src=\"http://blog.example/fig.png\""))
        #expect(!out.contains("One</a>"))
        #expect(!out.contains("© Example"))
        #expect(out.contains("href=\"http://blog.example/post?id=4\">Original page</a>"))
        #expect(!out.contains("class="))
        #expect(out.contains("charset=windows-1252"))
    }

    @Test func resolvesALazyLoadedImageBeforeCleaning() throws {
        let article = (0..<6).map { "<p>\($0) \(String(repeating: sentence, count: 3))</p>" }.joined()
        let html = """
        <html><head><title>A history</title></head><body>
        <div class="post-content"><h2>Origins</h2>\(article)
        <img data-src="/lazy.png" src="data:image/gif;base64,R0lGOD"></div>
        </body></html>
        """
        let out = try #require(try ReaderExtractor.extract(html: html, pageURL: page))
        #expect(out.contains("src=\"http://blog.example/lazy.png\""))
    }

    @Test func resolvesTheSmallestSrcsetCandidateBeforeCleaning() throws {
        let article = (0..<6).map { "<p>\($0) \(String(repeating: sentence, count: 3))</p>" }.joined()
        let html = """
        <html><head><title>A history</title></head><body>
        <div class="post-content"><h2>Origins</h2>\(article)
        <img srcset="/s.png 100w, /l.png 900w"></div>
        </body></html>
        """
        let out = try #require(try ReaderExtractor.extract(html: html, pageURL: page))
        #expect(out.contains("src=\"http://blog.example/s.png\""))
    }

    @Test func returnsNilWithoutARealArticle() throws {
        let html = "<html><body><a href=\"/a\">A</a> <a href=\"/b\">B</a><p>Short.</p></body></html>"
        #expect(try ReaderExtractor.extract(html: html, pageURL: page) == nil)
    }

    @Test func extractsALargePageQuickly() throws {
        let paragraph = "<p>" + String(repeating: "Magic Cap emulator performance test paragraph text. ", count: 4) + "</p>"
        let article = String(repeating: paragraph, count: 3000)
        let sidebarLink = "<a href=\"/link\">Link</a> "
        let sidebar = String(repeating: sidebarLink, count: 500)
        let html = """
        <html><head><title>Big page</title></head><body>
        <div class="sidebar">\(sidebar)</div>
        <div class="post">\(article)</div>
        </body></html>
        """
        let start = Date()
        _ = try ReaderExtractor.extract(html: html, pageURL: page)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0)
    }

    @Test func shortensAnArticleOverBudgetInDocumentOrder() throws {
        let article = (0..<400).map { "<p>Paragraph \($0) \(sentence)</p>" }.joined()
        let html = "<html><head><title>Long</title></head><body><div class=\"post-content\">\(article)</div></body></html>"
        let out = try #require(try ReaderExtractor.extract(html: html, pageURL: page, budget: 20_000))
        #expect(out.contains("Paragraph 0 "))
        #expect(!out.contains("Paragraph 399 "))
        #expect(out.contains("Article shortened. <a href=\"http://blog.example/post?id=4\">Original page</a>"))
        #expect(TextCoding.windows1252(out, html: true).count <= 20_000)
    }

    @Test func omitsTheShortenedNoteWithinBudget() throws {
        let article = (0..<6).map { "<p>\($0) \(String(repeating: sentence, count: 3))</p>" }.joined()
        let html = "<html><head><title>T</title></head><body><div class=\"post-content\">\(article)</div></body></html>"
        let out = try #require(try ReaderExtractor.extract(html: html, pageURL: page))
        #expect(!out.contains("Article shortened."))
    }
}
