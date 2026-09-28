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

    /// RGB of one pixel in the decoded image, via a fresh RGBX bitmap so the caller
    /// need not care about the source format's own byte layout.
    private func pixel(_ data: Data, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
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
        let flattened = try #require(pixel(out.data, x: 48, y: 16))   // was transparent; must be white now
        #expect(flattened.r >= 250 && flattened.g >= 250 && flattened.b >= 250)
    }

    @Test func shrinksOpaqueRGBAPhotosToJPEG() throws {
        // An RGBA-format image (alpha channel present) that is nonetheless fully
        // opaque everywhere must still be treated as a photo, not forced to GIF.
        let context = CGContext(data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<1000 {   // a gradient has far more than 256 colours
            context.setFillColor(red: CGFloat(x) / 1000, green: 0.5, blue: CGFloat(x % 97) / 97, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 500))
        }
        let png = try #require(encode(context.makeImage()!, as: .png))
        let out = ImageTranscoder.transcode(png)
        #expect(out.contentType == "image/jpeg")
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

    /// A flat grey PNG of the given size, drawn in 8-bit greyscale to keep
    /// the test's own memory use down (it still compresses to a few KB).
    private func flatPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(encode(image, as: .png))
    }

    @Test func capsVeryTallImagesAtAThousandPixels() throws {
        let out = ImageTranscoder.transcode(try flatPNG(width: 480, height: 40_000))
        let info = try #require(decoded(out.data))
        #expect(info.height <= ImageTranscoder.maxHeight)
        #expect(info.width <= ImageTranscoder.maxWidth && info.width >= 1)
        #expect(info.height == 1000 && info.width == 12)
    }

    @Test func refusesSourcesOverThePixelLimitQuickly() throws {
        // 7,000 x 7,000 = 49 megapixels, over the 40-megapixel limit.
        let png = try flatPNG(width: 7_000, height: 7_000)
        let start = Date()
        let out = ImageTranscoder.transcode(png)
        #expect(out == TranscodedImage(data: ImageTranscoder.placeholderGIF, contentType: "image/gif"))
        #expect(Date().timeIntervalSince(start) < 0.5)
    }
}
