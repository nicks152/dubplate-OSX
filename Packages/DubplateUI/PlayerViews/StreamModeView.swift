import SwiftUI
import DubplateCore
import DubplateAudio

/// Stream: dense, dark, contemporary.
///
/// Artwork sized to leave room for the sequence underneath, a bold title, and
/// controls close to the thumb. This is what a record looks like when someone is
/// half-listening on a train.
public struct StreamModeView: View {
    private let player: PlayerController
    private let artwork: ArtworkAsset?
    private let onShowVersions: (() -> Void)?
    private let onShowQueue: (() -> Void)?

    public init(
        player: PlayerController,
        artwork: ArtworkAsset?,
        onShowVersions: (() -> Void)? = nil,
        onShowQueue: (() -> Void)? = nil
    ) {
        self.player = player
        self.artwork = artwork
        self.onShowVersions = onShowVersions
        self.onShowQueue = onShowQueue
    }

    public var body: some View {
        GeometryReader { geometry in
            let artworkEdge = min(geometry.size.width - DubplateLayout.xxl * 2, geometry.size.height * 0.46)
            VStack(spacing: DubplateLayout.xl) {
                Spacer(minLength: DubplateLayout.l)

                ArtworkView(
                    asset: artwork,
                    title: player.currentItem?.releaseTitle ?? "",
                    cornerRadius: DubplateLayout.artworkRadius
                )
                .frame(width: max(120, artworkEdge), height: max(120, artworkEdge))
                .shadow(color: .black.opacity(0.5), radius: 34, y: 18)

                VStack(spacing: DubplateLayout.xs) {
                    // The record, so you know what you are inside.
                    Text(player.currentItem?.releaseTitle ?? "")
                        .dubplateLabelStyle(DubplateColor.playerSecondaryText)
                    Text(player.currentItem?.title ?? "")
                        .font(DubplateType.nowPlayingTitle)
                        .kerning(-0.48)
                        .foregroundStyle(DubplateColor.playerPrimaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(player.currentItem?.artistName ?? "")
                        .font(DubplateType.nowPlayingArtist)
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, DubplateLayout.xl)

                ScrubBar(
                    progress: player.progress,
                    elapsed: player.displayTime,
                    duration: player.duration,
                    peaks: player.currentItem?.waveformPeaks,
                    onScrubStart: { player.beginScrub(at: $0) },
                    onScrubChange: { player.updateScrub(to: $0) },
                    onScrubEnd: { player.endScrub() }
                )
                .padding(.horizontal, DubplateLayout.xl)

                TransportControls(player: player, size: .regular)

                Spacer(minLength: DubplateLayout.xxl)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                // Two text buttons at the top, rather than a stranded fragment of a
                // tab bar stacked under the transport.
                HStack(spacing: DubplateLayout.l) {
                    if let onShowQueue {
                        secondaryButton("Up Next", action: onShowQueue)
                    }
                    if let onShowVersions {
                        secondaryButton("Mixes", action: onShowVersions)
                    }
                }
                .padding(.trailing, DubplateLayout.l)
                .padding(.top, DubplateLayout.s)
            }
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DubplateColor.playerSecondaryText)
                .frame(minHeight: DubplateLayout.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}
