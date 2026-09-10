import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Reads image dimensions and builds the small rendition Dubplate shows in lists.
///
/// ImageIO rather than UIImage/NSImage so this can live in DubplateCore and work
/// the same on both platforms — and so reading a 6000px cover's dimensions does
/// not decode a 6000px cover.
public enum ImageInspector {

    /// Pixel dimensions without decoding the image. Zeroes when unreadable.
    public static func pixelSize(ofFileAt url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return (0, 0)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    /// Longest edge of the rendition stored alongside the artwork. Large enough for
    /// a Lock Screen on a 3x display, small enough to keep in the database.
    public static let thumbnailMaxPixel = 600

    /// A JPEG rendition used in lists, on the Lock Screen and in Control Centre.
    public static func thumbnailData(ofFileAt url: URL, maxPixel: Int = thumbnailMaxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(image)
    }

    /// A thumbnail from bytes already in memory, for Photos picks and pastes.
    public static func thumbnailData(from data: Data, maxPixel: Int = thumbnailMaxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(image)
    }

    public static func pixelSize(from data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return (0, 0)
        }
        return (
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
