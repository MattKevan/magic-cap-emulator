import Foundation
import Testing
@testable import DataRoverWeb

@Suite struct TextCodingTests {
    @Test func encodesLatin1AndWindowsPunctuationDirectly() {
        #expect(TextCoding.windows1252("café", html: true) == Data([0x63, 0x61, 0x66, 0xE9]))
        #expect(TextCoding.windows1252("€—“”’…", html: true) == Data([0x80, 0x97, 0x93, 0x94, 0x92, 0x85]))
    }

    @Test func escapesEverythingElse() {
        #expect(String(decoding: TextCoding.windows1252("a→b😀", html: true), as: UTF8.self) == "a&#8594;b&#128512;")
        #expect(String(decoding: TextCoding.windows1252("a→b", html: false), as: UTF8.self) == "a?b")
    }

    @Test func decodesUsingTheHeaderCharset() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(TextCoding.decode(latin1, contentType: "text/html; charset=ISO-8859-1") == "café")
        #expect(TextCoding.decode(Data("café".utf8), contentType: "text/html; charset=utf-8") == "café")
    }

    @Test func fallsBackToMetaCharsetThenUTF8() {
        var page = Data("<html><head><meta charset=\"iso-8859-1\"></head><body>caf".utf8)
        page.append(0xE9)
        #expect(TextCoding.decode(page, contentType: "text/html").hasSuffix("café"))
        #expect(TextCoding.decode(Data("café".utf8), contentType: nil) == "café")
    }

    @Test func dropsLeadingBOM() {
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data("café".utf8))
        #expect(TextCoding.decode(bom, contentType: "text/html; charset=utf-8") == "café")
        #expect(TextCoding.decode(bom, contentType: nil) == "café")
    }

    @Test func encodedLengthMatchesTheBytesSent() {
        for text in ["café", "€—“”’…", "漢字", "a\u{0081}b", "𐌲𐌿𐍄", "plain ascii"] {
            #expect(TextCoding.encodedLength(text) == TextCoding.windows1252(text, html: true).count, "\(text)")
        }
    }
}
