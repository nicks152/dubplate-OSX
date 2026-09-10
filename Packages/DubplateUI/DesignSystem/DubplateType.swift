import SwiftUI

/// Type styles.
///
/// System font throughout — no licensed face is bundled — but used editorially
/// rather than the way a settings screen uses it: display sizes are large and
/// tightly tracked, metadata is small and widely tracked, and there are only a
/// handful of steps so the hierarchy stays obvious.
public enum DubplateType {

    /// The four display steps. A record's title is one of these and nothing else,
    /// so the same record reads the same way on both platforms.
    public enum Display: CGFloat {
        case page = 44
        case screen = 30
        case sheet = 22
        case inline = 17
    }

    public static func display(_ step: Display = .page) -> Font {
        .system(size: step.rawValue, weight: .semibold)
    }

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

    /// Display titles are tracked in, the way set type is — proportionally, so the
    /// character survives the step down instead of loosening at small sizes.
    ///
    /// No `minimumScaleFactor`: silently shrinking a 44pt title to 30.8pt is a
    /// settings-screen reflex. Two lines are designed for; three is a wrap.
    func dubplateDisplayStyle(_ step: DubplateType.Display = .page) -> some View {
        self
            .font(DubplateType.display(step))
            .kerning(step.rawValue * -0.022)
            .lineLimit(2)
    }
}
