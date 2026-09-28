import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct PageSimplifierTests {
    private let page = URL(string: "https://news.example/story/1")!

    private func simplify(_ body: String, head: String = "", budget: Int = PageSimplifier.budget) throws -> String {
        try PageSimplifier.simplify(html: "<html><head>\(head)</head><body>\(body)</body></html>", pageURL: page, budget: budget)
    }

    @Test func removesHeavyAndHiddenElements() throws {
        let out = try simplify("""
        <script>x()</script><noscript>n</noscript><style>p{}</style><iframe src="a"></iframe><svg></svg>
        <video></video><audio></audio><canvas></canvas><template>t</template>
        <div hidden>h</div><div aria-hidden="true">a</div><div style="display:none">d</div>
        <img src="/px.gif" width="1" height="1"><div id="cookie-banner">Accept cookies</div>
        <p>Keep me</p>
        """, head: "<link rel=\"stylesheet\" href=\"/s.css\">")
        for gone in ["<script", "<noscript", "<style", "<iframe", "<svg", "<video", "<audio", "<canvas",
                     "<template", ">h<", ">a<", ">d<", "px.gif", "Accept cookies", "s.css"] {
            #expect(!out.contains(gone), "\(gone)")
        }
        #expect(out.contains("Keep me"))
    }

    @Test func rewritesLinksToAbsoluteHTTP() throws {
        let out = try simplify("""
        <a href="/a">rel</a><a href="https://other.example/b">abs</a><a href="//cdn.example/c">proto</a>
        <a href="javascript:void(0)">js</a><form action="/search"></form><form></form>
        """)
        #expect(out.contains("href=\"http://news.example/a\""))
        #expect(out.contains("href=\"http://other.example/b\""))
        #expect(out.contains("href=\"http://cdn.example/c\""))
        #expect(!out.contains("javascript:"))
        #expect(out.contains("action=\"http://news.example/search\""))
        #expect(out.contains("action=\"http://news.example/story/1\""))
    }

    @Test func honoursBaseHref() throws {
        let out = try simplify("<a href=\"x\">x</a><img src=\"i.png\">", head: "<base href=\"https://static.example/dir/\">")
        #expect(out.contains("href=\"http://static.example/dir/x\""))
        #expect(out.contains("src=\"http://static.example/dir/i.png\""))
    }

    @Test func picksOneImageSourceAndCapsItsSize() throws {
        let out = try simplify("""
        <img srcset="/s.jpg 320w, /m.jpg 640w, /l.jpg 1280w" sizes="100vw" loading="lazy" width="1280" height="640">
        <img src="data:image/gif;base64,R0lGOD" data-src="/lazy.jpg">
        """)
        #expect(out.contains("src=\"http://news.example/s.jpg\""))
        #expect(out.contains("width=\"480\""))
        #expect(out.contains("height=\"240\""))
        #expect(!out.contains("srcset") && !out.contains("loading="))
        #expect(out.contains("src=\"http://news.example/lazy.jpg\""))
    }

    @Test func flattensMenusAndStripsPresentationalAttributes() throws {
        let out = try simplify("""
        <nav class="menu"><ul><li><a href="/n">News</a></li><li><a href="/s">Sport</a></li></ul></nav>
        <p class="x" style="color:red" onclick="go()">Text</p>
        """)
        #expect(!out.contains("<nav"))
        #expect(out.contains("News</a> | <a"))
        #expect(!out.contains("class=") && !out.contains("style=") && !out.contains("onclick"))
    }

    @Test func addsTheToolbarAndCharset() throws {
        let out = try simplify("<p>x</p>", head: "<meta charset=\"utf-8\">")
        #expect(out.contains("href=\"http://news.example/story/1?mcreader=1\">Reader view</a>"))
        #expect(out.contains("href=\"http://10.0.2.2/\">Start page</a>"))
        #expect(out.contains("charset=windows-1252"))
        #expect(!out.contains("charset=\"utf-8\""))
    }

    @Test func shortensPagesOverBudget() throws {
        let paragraphs = (0..<400).map { "<p>Paragraph \($0) " + String(repeating: "word ", count: 40) + "</p>" }.joined()
        let out = try simplify("<div><div>\(paragraphs)</div></div>", budget: 20_000)
        #expect(out.utf8.count < 22_000)
        #expect(out.contains("Paragraph 0 "))
        #expect(!out.contains("Paragraph 399 "))
        #expect(out.contains("Page shortened."))
    }
}
