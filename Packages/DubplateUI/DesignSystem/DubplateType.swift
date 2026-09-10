import SwiftUI

/// Type styles.
///
/// System font throughout — no licensed face is bundled — but used editorially
/// rather than the way a settings screen uses it: display sizes are large and
/// tightly tracked, metadata is small and widely tracked, and there are only a
/// handful of steps so the hierarchy stays obvious.
public enum DubplateType {

    /// A release title on its own page. Big, tight, confident.
    public static func display(_ size: CGFloat = 44) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Section titles: "Recently Played", "Your Music".
    public static let sectionTitle = Font.system(size: 13, weight: .semibold)

    /// Release names in the grid.
    public static let cardTitle = Font.system(size: 14, weight: .medium)

    /// Track titles in a list.
    public static let rowTitle = Font.system(size: 14, weight: .regular)

    /// Artist under a title.
    public static let rowSubtitle = Font.system(size: 13, weight: .regular)

    /// Durations, track numbers, "24-bit / 48 kHz".
    public static let metadata = Font.system(size: 12, weight: .regular).monospacedDigit()

    /// Small uppercase labels above fields.
    public static let label = Font.system(size: 10, weight: .semibold)

    /// Now Playing title.
    public static let nowPlayingTitle = Font.system(size: 22, weight: .semibold)
    public static let nowPlayingArtist = Font.system(size: 17, weight: .regular)
}

public extension View {
    /// The wide-tracked uppercase treatment used for labels and section headers.
    func dubplateLabelStyle(_ color: Color = DubplateColor.tertiaryText) -> some View {
        self
            .font(DubplateType.label)
            .textCase(.uppercase)
            .kerning(1.1)
            .foregroundStyle(color)
    }

    /// Display titles are tracked in slightly at large sizes, the way set type is.
    func dubplateDisplayStyle(size: CGFloat = 44) -> some View {
        self
            .font(DubplateType.display(size))
            .kerning(size >= 34 ? -0.8 : -0.3)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
    }
}
