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
                    cornerRadius: DubplateLayout.largeArtworkRadius
                )
                .frame(width: max(120, artworkEdge), height: max(120, artworkEdge))
                .shadow(color: .black.opacity(0.5), radius: 34, y: 18)

                VStack(spacing: DubplateLayout.xs) {
                    Text(player.currentItem?.title ?? "Nothing playing")
                        .font(DubplateType.nowPlayingTitle)
                        .kerning(-0.4)
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

                HStack(spacing: DubplateLayout.xxl) {
                    if let onShowVersions {
                        secondaryButton("Versions", systemImage: "square.stack", action: onShowVersions)
                    }
                    if let onShowQueue {
                        secondaryButton("Up Next", systemImage: "list.bullet", action: onShowQueue)
                    }
                }

                Spacer(minLength: DubplateLayout.xxxl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func secondaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(DubplateColor.playerSecondaryText)
            .frame(minWidth: DubplateLayout.minimumTapTarget, minHeight: DubplateLayout.minimumTapTarget)
        }
        .buttonStyle(PressableButtonStyle())
    }
}
