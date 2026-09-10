import SwiftUI

/// One type style: the size the design chose, and the system text style it follows
/// when someone turns text size up.
///
/// Sizes are not text styles. A record's title is 44pt because 44pt is what a
/// sleeve looks like, not because `largeTitle` happens to be near it. But a fixed
/// point size ignores Dynamic Type entirely, and 12pt metadata that stays 12pt for
/// a person who has turned iOS text size up is not a design decision, it is a
/// missing one. So each style keeps its size and scales with the text style closest
/// to its role.
public struct DubplateFont: Sendable, Equatable {
    public let size: CGFloat
    public let weight: Font.Weight
    /// The system text style this scales with.
    public let textStyle: Font.TextStyle
    /// The most it may grow, as a multiple of its size.
    ///
    /// Display type is set at a size *and* a tracking, and past a point the two
    /// stop working together — a 44pt sleeve title at 3× is one word per line.
    /// Reading type has no such ceiling and is capped generously.
    public let maximumScale: CGFloat
    public let usesMonospacedDigits: Bool

    public init(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body,
        maximumScale: CGFloat = 2.4,
        usesMonospacedDigits: Bool = false
    ) {
        self.size = size
        self.weight = weight
        self.textStyle = textStyle
        self.maximumScale = maximumScale
        self.usesMonospacedDigits = usesMonospacedDigits
    }

    /// The `Font` for a given scale, which the modifier reads from the environment.
    public func resolved(scale: CGFloat) -> Font {
        let font = Font.system(size: size * min(scale, maximumScale), weight: weight)
        return usesMonospacedDigits ? font.monospacedDigit() : font
    }

    /// A one-off size that still scales. Used where a view needs a size the token
    /// list does not have; `.system(size:)` on its own does not scale at all.
    public static func fixed(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> DubplateFont {
        DubplateFont(size: size, weight: weight, relativeTo: textStyle)
    }
}

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

    public static func display(_ step: Display = .page) -> DubplateFont {
        DubplateFont(
            size: step.rawValue,
            weight: .semibold,
            relativeTo: step == .inline ? .headline : .largeTitle,
            // Least room to grow at the top of the scale, where the type is
            // already large and a sleeve title has two lines to live in.
            maximumScale: step == .page ? 1.5 : 1.8
        )
    }

    /// Release names in the grid.
    public static let cardTitle = DubplateFont(size: 14, weight: .medium, relativeTo: .footnote)

    /// Track titles in a list.
    public static let rowTitle = DubplateFont(size: 14, relativeTo: .footnote)

    /// The track that is playing. One step of weight, which is the only difference
    /// available in a palette that has no second colour.
    public static let rowTitleCurrent = DubplateFont(size: 14, weight: .medium, relativeTo: .footnote)

    /// Artist under a title.
    public static let rowSubtitle = DubplateFont(size: 13, relativeTo: .footnote)

    /// Durations, track numbers, "24-bit / 48 kHz".
    public static let metadata = DubplateFont(
        size: 12,
        relativeTo: .caption,
        usesMonospacedDigits: true
    )

    /// Small uppercase labels above fields.
    public static let label = DubplateFont(size: 10, weight: .semibold, relativeTo: .caption2)

    /// Now Playing title.
    public static let nowPlayingTitle = DubplateFont(size: 22, weight: .semibold, relativeTo: .title2, maximumScale: 1.8)
    public static let nowPlayingArtist = DubplateFont(size: 17, relativeTo: .body, maximumScale: 1.8)
}

/// Applies a Dubplate type style, scaled to the reader's text size.
///
/// A `ViewModifier` rather than a `Font` constant because the scale lives in the
/// environment and only a view can read it. `@ScaledMetric` returns 1 on macOS,
/// which has no Dynamic Type, so the same call is exact there.
struct DubplateScaledFont: ViewModifier {
    private let font: DubplateFont
    @ScaledMetric private var scale: CGFloat

    init(_ font: DubplateFont) {
        self.font = font
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: font.textStyle)
    }

    func body(content: Content) -> some View {
        content.font(font.resolved(scale: scale))
    }
}

public extension View {
    /// Sets one of Dubplate's type styles.
    func dubplateFont(_ font: DubplateFont) -> some View {
        modifier(DubplateScaledFont(font))
    }

    /// The wide-tracked uppercase treatment used for labels and section headers.
    func dubplateLabelStyle(_ color: Color = DubplateColor.tertiaryText) -> some View {
        self
            .dubplateFont(DubplateType.label)
            .textCase(.uppercase)
            .kerning(1.1)
            .foregroundStyle(color)
    }

    /// Display titles are tracked in, the way set type is — proportionally, so the
    /// character survives the step down instead of loosening at small sizes.
    ///
    /// No `minimumScaleFactor`: silently shrinking a 44pt title to 30.8pt is a
    /// settings-screen reflex. Two lines are designed for; three is a wrap, and at
    /// the accessibility sizes the limit lifts rather than the type shrinking.
    func dubplateDisplayStyle(_ step: DubplateType.Display = .page) -> some View {
        self
            .dubplateFont(DubplateType.display(step))
            .kerning(step.rawValue * -0.022)
            .lineLimit(step == .page ? 3 : 2)
    }
}
