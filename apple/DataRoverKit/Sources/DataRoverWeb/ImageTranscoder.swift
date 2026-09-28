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
    public static let placeholderGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")!

    private static var placeholder: TranscodedImage { TranscodedImage(data: placeholderGIF, contentType: "image/gif") }

    public static func transcode(_ data: Data) -> TranscodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return placeholder }
        let width = min(full.width, maxWidth)
        let height = max(1, Int((Double(full.height) * Double(width) / Double(full.width)).rounded()))
        let hadAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(full.alphaInfo)

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return placeholder }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)       // flatten onto white
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
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
