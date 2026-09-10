import SwiftUI

/// Spacing, radii and the sizes that repeat across both applications.
///
/// One scale, used everywhere. When a view needs a value that is not on the scale,
/// that is usually a sign the view is wrong rather than the scale.
public enum DubplateLayout {
    public static let hairline: CGFloat = 1

    /// 4-point scale.
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    /// Artwork corners. Small: a sleeve is square, not a rounded app icon.
    public static let artworkRadius: CGFloat = 6
    public static let largeArtworkRadius: CGFloat = 10
    public static let controlRadius: CGFloat = 8
    public static let sheetRadius: CGFloat = 14

    /// Minimum hit target. Below this nothing is tappable.
    public static let minimumTapTarget: CGFloat = 44

    /// Grid metrics for the library.
    public static let gridMinimumCardWidth: CGFloat = 168
    public static let gridMaximumCardWidth: CGFloat = 260
    public static let gridSpacing: CGFloat = 20

    /// Track row height on each platform.
    #if os(macOS)
    public static let trackRowHeight: CGFloat = 34
    #else
    public static let trackRowHeight: CGFloat = 56
    #endif
}

/// Animation.
///
/// Three curves, used for everything. Reduce Motion is honoured by every one of
/// them, because a producer scrubbing a mix does not need the interface moving.
public enum DubplateMotion {
    /// Selections, hovers, toggles.
    public static let quick = Animation.easeOut(duration: 0.16)
    /// Rearranging a track list, expanding a version list.
    public static let standard = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// Opening artwork, entering Now Playing.
    public static let expressive = Animation.spring(response: 0.48, dampingFraction: 0.78)

    /// The same curves, flattened when the person has asked for less motion.
    public static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? .easeInOut(duration: 0.12) : animation
    }
}
