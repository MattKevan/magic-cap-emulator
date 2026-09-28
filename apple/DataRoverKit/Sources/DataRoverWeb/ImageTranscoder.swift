import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct TranscodedImage: Equatable, Sendable {
    public var data: Data
    public var contentType: String
    public init(data: Data, contentType: String) { self.data = data; self.contentType = contentType }
}

/// Converts any image ImageIO can decode into a small GIF or JPEG.
public enum ImageTranscoder {
    public static let maxWidth = 480
    public static let maxHeight = 1000
    public static let placeholderGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")!

    private static var placeholder: TranscodedImage { TranscodedImage(data: placeholderGIF, contentType: "image/gif") }

    /// Sources over this many pixels are refused (placeholder) before any
    /// decoding: even a thumbnail decode of one can need hundreds of MB.
    public static let maxSourcePixels = 40_000_000

    public static func transcode(_ data: Data) -> TranscodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = displaySize(source), size.width > 0, size.height > 0,
              size.width * size.height <= maxSourcePixels else { return placeholder }
        // Decode straight to the output size (at most maxWidth wide and
        // maxHeight tall, aspect ratio kept) instead of decoding the full
        // source and scaling it afterwards.
        let scale = min(1, Double(maxWidth) / Double(size.width), Double(maxHeight) / Double(size.height))
        let longSide = max(1, Int((Double(max(size.width, size.height)) * scale).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return placeholder }
        let width = max(1, min(scaled.width, maxWidth))
        let height = max(1, min(scaled.height, maxHeight))
        let formatHasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(scaled.alphaInfo)
        let hadAlpha = formatHasAlpha && hasTransparentPixel(scaled, width: width, height: height)

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return placeholder }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)       // flatten onto white
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(scaled, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else { return placeholder }

        let useGIF = hadAlpha || colourCount(context, limit: 257) <= 256
        let type = useGIF ? UTType.gif : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            return placeholder
        }
        let properties = useGIF ? nil : [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary
        CGImageDestinationAddImage(destination, flat, properties)
        guard CGImageDestinationFinalize(destination) else { return placeholder }
        return TranscodedImage(data: out as Data, contentType: useGIF ? "image/gif" : "image/jpeg")
    }

    /// The source's pixel size as displayed (width and height swapped for
    /// EXIF orientations 5-8), read from its properties without decoding.
    private static func displaySize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// Whether any pixel of `image`, rendered at `width`×`height`, is not fully opaque.
    /// The format can *declare* an alpha channel (e.g. a plain RGBA photo) without any
    /// pixel actually using it, so this renders and inspects the real alpha bytes rather
    /// than trusting `CGImageAlphaInfo` alone.
    private static func hasTransparentPixel(_ image: CGImage, width: Int, height: Int) -> Bool {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data else { return true }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))   // start fully transparent
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for pixel in 0..<(width * height) {
            if bytes[pixel * 4 + 3] < 255 { return true }
        }
        return false
    }

    /// Distinct RGB colours in the bitmap, counting no higher than `limit`.
    private static func colourCount(_ context: CGContext, limit: Int) -> Int {
        guard let base = context.data else { return limit }
        let pixels = base.bindMemory(to: UInt32.self, capacity: context.width * context.height)
        var seen = Set<UInt32>()
        for index in 0..<(context.width * context.height) {
            seen.insert(pixels[index] & 0x00FF_FFFF)
            if seen.count >= limit { break }
        }
        return seen.count
    }
}

/// Transcoded images by upstream URL; pages reuse icons and logos.
public final class ImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, Box>()
    private final class Box { let image: TranscodedImage; init(_ image: TranscodedImage) { self.image = image } }

    public init(limit: Int = 4 * 1024 * 1024) { cache.totalCostLimit = limit }

    public func image(for key: String) -> TranscodedImage? { cache.object(forKey: key as NSString)?.image }

    public func store(_ image: TranscodedImage, for key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.data.count)
    }
}
