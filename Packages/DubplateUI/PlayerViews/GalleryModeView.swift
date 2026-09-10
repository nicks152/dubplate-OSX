import SwiftUI
import DubplateCore
import DubplateAudio

/// Gallery: artwork-forward and editorial.
///
/// Large art, generous space, type that behaves like a printed sleeve — the title
/// set left, the credit small underneath, the transport reduced to what it has to
/// be. This is the record as an object.
public struct GalleryModeView: View {
    private let player: PlayerController
    private let artwork: ArtworkAsset?
    private let onShowVersions: (() -> Void)?

    public init(player: PlayerController, artwork: ArtworkAsset?, onShowVersions: (() -> Void)? = nil) {
        self.player = player
        self.artwork = artwork
        self.onShowVersions = onShowVersions
    }

    public var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height * 1.1
            let artworkEdge = isWide
                ? geometry.size.height * 0.72
                : min(geometry.size.width - DubplateLayout.xl * 2, geometry.size.height * 0.56)

            Group {
                if isWide {
                    HStack(spacing: DubplateLayout.xxxl) {
                        art(edge: artworkEdge)
                        details(alignment: .leading)
                            .frame(maxWidth: 380)
                    }
                    .padding(DubplateLayout.xxxl)
                } else {
                    VStack(alignment: .leading, spacing: DubplateLayout.xxl) {
                        Spacer(minLength: 0)
                        art(edge: artworkEdge)
                            .frame(maxWidth: .infinity)
                        details(alignment: .leading)
                        Spacer(minLength: DubplateLayout.xxxl)
                    }
                    .padding(.horizontal, DubplateLayout.xl)
                }
            }
        }
    }

    private func art(edge: CGFloat) -> some View {
        ArtworkView(
            asset: artwork,
            title: player.currentItem?.releaseTitle ?? "",
            cornerRadius: 2
        )
        .frame(width: max(140, edge), height: max(140, edge))
        .shadow(color: .black.opacity(0.55), radius: 44, y: 24)
    }

    private func details(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DubplateLayout.l) {
            VStack(alignment: alignment, spacing: DubplateLayout.s) {
                Text(player.currentItem?.releaseTitle ?? "")
                    .dubplateLabelStyle(DubplateColor.playerSecondaryText)

                Text(player.currentItem?.title ?? "Nothing playing")
                    .font(.system(size: 34, weight: .semibold))
                    .kerning(-0.9)
                    .foregroundStyle(DubplateColor.playerPrimaryText)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)

                Text(player.currentItem?.artistName ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(DubplateColor.playerSecondaryText)

                if let format = player.currentItem?.format, format.isKnown {
                    Text(format.summary)
                        .font(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.playerSecondaryText.opacity(0.7))
                }
            }

            ScrubBar(
                progress: player.progress,
                elapsed: player.displayTime,
                duration: player.duration,
                peaks: player.currentItem?.waveformPeaks,
                onScrubStart: { player.beginScrub(at: $0) },
                onScrubChange: { player.updateScrub(to: $0) },
                onScrubEnd: { player.endScrub() }
            )

            HStack(spacing: DubplateLayout.xl) {
                TransportControls(player: player, size: .regular, showsModes: false)
                Spacer()
                if let onShowVersions {
                    Button("Versions", action: onShowVersions)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                }
            }
        }
    }
}
