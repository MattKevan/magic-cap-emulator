import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DataRoverWeb

@Suite struct ImageTranscoderTests {
    private func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func photo(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {   // a gradient has far more than 256 colours
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.5, blue: CGFloat(x % 97) / 97, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()!
    }

    private func decoded(_ data: Data) -> (type: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return (type as String, image.width, image.height)
    }

    @Test func shrinksPhotosToJPEG() throws {
        let png = try #require(encode(photo(width: 1000, height: 500), as: .png))
        let out = ImageTranscoder.transcode(png)
        #expect(out.contentType == "image/jpeg")
        let info = try #require(decoded(out.data))
        #expect(info.width == 480 && info.height == 240)
    }

    @Test func keepsSmallFlatImagesAsGIFOnWhite() throws {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))   // right half stays transparent
        let png = try #require(encode(context.makeImage()!, as: .png))
        let out = ImageTranscoder.transcode(png)
        #expect(out.contentType == "image/gif")
        let info = try #require(decoded(out.data))
        #expect(info.width == 64 && info.height == 32)
    }

    @Test func decodesWebP() throws {
        // 1×1 lossless WebP (the widely used feature-detection sample).
        let webp = try #require(Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="))
        let out = ImageTranscoder.transcode(webp)
        #expect(out.contentType == "image/gif")
        #expect(decoded(out.data)?.width == 1)
    }

    @Test func decodesAVIFWhenTheSystemCanWriteIt() throws {
        // UTType.avif is not exposed as a static member by this SDK's UniformTypeIdentifiers
        // overlay, so the identifier is constructed directly; behaviour is unchanged.
        let avifIdentifier = "public.avif"
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(avifIdentifier), let avifType = UTType(avifIdentifier) else { return }
        let avif = try #require(encode(photo(width: 600, height: 300), as: avifType))
        let out = ImageTranscoder.transcode(avif)
        #expect(decoded(out.data)?.width == 480)
    }

    @Test func replacesUndecodableImagesWithAPlaceholder() {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8)
        #expect(ImageTranscoder.transcode(svg) == TranscodedImage(data: ImageTranscoder.placeholderGIF, contentType: "image/gif"))
    }

    @Test func cachesByKey() {
        let cache = ImageCache(limit: 1024)
        let image = TranscodedImage(data: Data([1, 2, 3]), contentType: "image/gif")
        cache.store(image, for: "http://e.com/a.png")
        #expect(cache.image(for: "http://e.com/a.png") == image)
        #expect(cache.image(for: "http://e.com/b.png") == nil)
    }
}
