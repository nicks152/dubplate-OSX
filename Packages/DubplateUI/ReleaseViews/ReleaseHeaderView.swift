import SwiftUI
import DubplateCore

/// The top of a release page: artwork, title, credit, and the two buttons that
/// start the record.
///
/// The same component on both platforms, laid out side-by-side where there is width
/// and stacked where there is not — a record's identity should not change shape
/// depending on which device you opened it on.
public struct ReleaseHeaderView: View {
    public enum Layout {
        /// Artwork left, type right. Mac release page.
        case horizontal
        /// Artwork centred above the type. iPhone release page.
        case centred
    }

    private let release: Release
    private let layout: Layout
    private let artworkEdge: CGFloat
    private let onPlay: () -> Void
    private let onShuffle: () -> Void
    private let onEditArtwork: (() -> Void)?

    public init(
        release: Release,
        layout: Layout = .horizontal,
        artworkEdge: CGFloat = 220,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        onEditArtwork: (() -> Void)? = nil
    ) {
        self.release = release
        self.layout = layout
        self.artworkEdge = artworkEdge
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.onEditArtwork = onEditArtwork
    }

    public var body: some View {
        switch layout {
        case .horizontal:
            HStack(alignment: .bottom, spacing: DubplateLayout.xl) {
                artwork
                VStack(alignment: .leading, spacing: DubplateLayout.m) {
                    text(alignment: .leading)
                    buttons
                }
                Spacer(minLength: 0)
            }
        case .centred:
            VStack(spacing: DubplateLayout.l) {
                artwork
                text(alignment: .center)
                buttons
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var artwork: some View {
        ArtworkView(
            asset: release.artwork,
            title: release.title,
            cornerRadius: DubplateLayout.largeArtworkRadius
        )
        .frame(width: artworkEdge, height: artworkEdge)
        .shadow(color: .black.opacity(0.3), radius: 26, y: 12)
        .contentShape(Rectangle())
        .onTapGesture { onEditArtwork?() }
        .accessibilityAddTraits(onEditArtwork == nil ? [] : .isButton)
        .accessibilityHint(onEditArtwork == nil ? "" : "Change artwork")
    }

    private func text(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DubplateLayout.xs) {
            Text(release.releaseType.displayName)
                .dubplateLabelStyle()

            Text(release.title.isEmpty ? "Untitled" : release.title)
                .dubplateDisplayStyle(size: layout == .centred ? 30 : 44)
                .foregroundStyle(DubplateColor.primaryText)
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)

            Text(release.artistName)
                .font(.system(size: layout == .centred ? 16 : 18, weight: .medium))
                .foregroundStyle(DubplateColor.secondaryText)

            Text(metadataLine)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }

    private var buttons: some View {
        HStack(spacing: DubplateLayout.m) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(DubplateFilledButtonStyle())
            .disabled(release.trackCount == 0)

            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(DubplateQuietButtonStyle())
            .disabled(release.trackCount < 2)
        }
        .labelStyle(.titleAndIcon)
    }

    private var metadataLine: String {
        var parts = [release.subtitleLine]
        if let year = release.year { parts.append(String(year)) }
        if release.totalDuration > 0 {
            parts.append(Formatting.longDuration(release.totalDuration))
        }
        return parts.joined(separator: " · ")
    }
}
