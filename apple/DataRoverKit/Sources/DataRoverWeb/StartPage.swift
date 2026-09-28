/// The proxy's own page at http://10.0.2.2/ — search and a few starting points.
public enum StartPage {
    public static let host = "10.0.2.2"

    public static func html() -> String {
        """
        <html><head><title>Start page</title></head><body>
        <h1>Web</h1>
        <form action="http://html.duckduckgo.com/html/" method="get">
        <input type="text" name="q" size="24"> <input type="submit" value="Search">
        </form>
        <p><a href="http://en.wikipedia.org/">Wikipedia</a><br>
        <a href="http://68k.news/">68k.news</a><br>
        <a href="http://lite.cnn.com/">CNN Lite</a><br>
        <a href="http://text.npr.org/">NPR text</a></p>
        <p>Pages are simplified to fit. If a page is still too big, use Reader view at the top of the page.</p>
        </body></html>
        """
    }
}
