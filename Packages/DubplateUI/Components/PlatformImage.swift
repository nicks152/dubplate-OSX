import SwiftUI

#if os(iOS)
import UIKit
public typealias DubplateImage = UIImage
#else
import AppKit
public typealias DubplateImage = NSImage
#endif

public extension Image {
    /// Wraps a platform image without either application needing `#if os(…)`.
    init(dubplate image: DubplateImage) {
        #if os(iOS)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

public extension DubplateImage {
    /// Builds a platform image from a decoded `CGImage`.
    static func make(from cgImage: CGImage) -> DubplateImage {
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
