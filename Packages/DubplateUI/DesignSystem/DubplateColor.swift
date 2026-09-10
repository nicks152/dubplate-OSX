import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Dubplate's palette.
///
/// Almost no colour: a near-black ground, a warm off-white, and four steps of grey
/// between them. Everything that is coloured in Dubplate is the artwork. This is a
/// deliberate constraint — the moment the interface introduces its own hue it
/// starts competing with the record.
public enum DubplateColor {

    /// The page. Ink-black rather than pure black so artwork edges stay visible.
    public static let ground = adaptive(light: 0xF7F6F4, dark: 0x0B0B0C)
    /// Cards, sheets, the sidebar — one step off the ground.
    public static let raised = adaptive(light: 0xFFFFFF, dark: 0x141416)
    /// Fills behind controls.
    public static let sunken = adaptive(light: 0xEDEBE7, dark: 0x1C1C1F)
    /// Hairlines. Never a full-strength border.
    public static let hairline = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)

    /// Titles.
    public static let primaryText = adaptive(light: 0x121212, dark: 0xF4F3F1)
    /// Artist names, durations, everything secondary.
    public static let secondaryText = adaptive(light: 0x121212, dark: 0xF4F3F1, lightAlpha: 0.58, darkAlpha: 0.60)
    /// Metadata labels, format strings, timestamps.
    ///
    /// 0.50 rather than 0.38: this is the colour of every duration, format string,
    /// date and filename in the product, at 12pt, and 0.38 over the ground blends to
    /// roughly 3.3:1 — below AA for text at that size. Nothing nests further opacity
    /// on top of it.
    public static let tertiaryText = adaptive(light: 0x121212, dark: 0xF4F3F1, lightAlpha: 0.48, darkAlpha: 0.50)

    /// The one accent, used for the playing indicator and the active version.
    /// A warm bone rather than a brand blue.
    public static let accent = adaptive(light: 0x121212, dark: 0xF4F3F1)

    /// Something needs attention — a missing file, a failed transfer.
    public static let alert = adaptive(light: 0xB4442F, dark: 0xE0684E)

    /// Player surfaces are dark in both appearances, the way a record sleeve is.
    public static let playerGround = Color(red: 0.043, green: 0.043, blue: 0.047)
    public static let playerPrimaryText = Color(red: 0.957, green: 0.953, blue: 0.945)
    public static let playerSecondaryText = Color(white: 0.96).opacity(0.62)

    // MARK: - Platform bridge

    static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightAlpha: Double = 1,
        darkAlpha: Double = 1
    ) -> Color {
        #if os(iOS)
        return Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(rgb: dark, alpha: darkAlpha)
                    : UIColor(rgb: light, alpha: lightAlpha)
            }
        )
        #else
        return Color(
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark
                    ? NSColor(rgb: dark, alpha: darkAlpha)
                    : NSColor(rgb: light, alpha: lightAlpha)
            }
        )
        #endif
    }
}

#if os(iOS)
extension UIColor {
    convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#else
extension NSColor {
    convenience init(rgb: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
#endif
