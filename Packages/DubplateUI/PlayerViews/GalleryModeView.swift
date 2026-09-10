import SwiftUI
import DubplateCore
import DubplateAudio

/// Gallery: the record as an object.
///
/// Not Stream with more margin — that was a spacing variant sold as an environment.
/// This is the sleeve: the cover, the running order beside or beneath it with the
/// playing track marked, and the credits a real release carries. It is the mode you
/// sit with, so it is the one that has something to read.
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
                ? geometry.size.height * 0.64
                : min(geometry.size.width - DubplateLayout.xl * 2, geometry.size.height * 0.42)

            Group {
                if isWide {
                    HStack(alignment: .top, spacing: DubplateLayout.xxxl) {
                        art(edge: artworkEdge)
                        ScrollView {
                            details(alignment: .leading)
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(DubplateLayout.xxxl)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DubplateLayout.xl) {
                            art(edge: artworkEdge)
                                .frame(maxWidth: .infinity)
                            details(alignment: .leading)
                        }
                        .padding(.horizontal, DubplateLayout.xl)
                        .padding(.vertical, DubplateLayout.xxl)
                    }
                }
            }
        }
    }

    private func art(edge: CGFloat) -> some View {
        ArtworkView(
            asset: artwork,
            title: player.currentItem?.releaseTitle ?? "",
            cornerRadius: 4
        )
        .frame(width: max(140, edge), height: max(140, edge))
        .shadow(color: .black.opacity(0.55), radius: 44, y: 24)
    }

    private func details(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DubplateLayout.l) {
            VStack(alignment: alignment, spacing: DubplateLayout.s) {
                Text(player.currentItem?.releaseTitle ?? "")
                    .dubplateLabelStyle(DubplateColor.playerSecondaryText)

                Text(player.currentItem?.title ?? "")
                    .dubplateDisplayStyle(.screen)
                    .foregroundStyle(DubplateColor.playerPrimaryText)

                Text(player.currentItem?.artistName ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(DubplateColor.playerSecondaryText)
            }

            runningOrder

            ScrubBar(
                progress: player.progress,
                elapsed: player.displayTime,
                duration: player.duration,
                peaks: player.currentItem?.waveformPeaks,
                onScrubStart: { player.beginScrub(at: $0) },
                onScrubChange: { player.updateScrub(to: $0) },
                onScrubEnd: { player.endScrub() }
            )

            HStack(spacing: DubplateLayout.m) {
                TransportControls(player: player, size: .regular, showsModes: false)
                Spacer()
                if let onShowVersions {
                    Button("Mixes", action: onShowVersions)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                }
            }

            credits
        }
    }

    /// The sequence, with where you are in it. This is what Stream cannot have and
    /// what makes Gallery a different way of hearing the same record.
    private var runningOrder: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(player.queue.items) { item in
                let isCurrent = item.id == player.currentItem?.id
                Button {
                    player.skip(to: item)
                } label: {
                    HStack(spacing: DubplateLayout.m) {
                        Text("\(item.trackNumber)")
                            .font(DubplateType.metadata)
                            .foregroundStyle(DubplateColor.playerSecondaryText)
                            .frame(width: 18, alignment: .trailing)
                        Text(item.title)
                            .font(.system(size: 15, weight: isCurrent ? .medium : .regular))
                            .foregroundStyle(
                                isCurrent ? DubplateColor.playerPrimaryText : DubplateColor.playerSecondaryText
                            )
                            .lineLimit(1)
                        Spacer(minLength: DubplateLayout.s)
                        Text(Formatting.duration(item.duration))
                            .font(DubplateType.metadata)
                            .foregroundStyle(DubplateColor.playerSecondaryText)
                    }
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// What is printed on the back of a sleeve.
    private var credits: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let format = player.currentItem?.format, format.isKnown {
                Text(format.summary)
            }
            if let release = player.currentItem?.releaseTitle, !release.isEmpty {
                Text("\(release) · \(player.currentItem?.artistName ?? "")")
            }
        }
        .font(DubplateType.metadata)
        .foregroundStyle(DubplateColor.playerSecondaryText)
    }
}
