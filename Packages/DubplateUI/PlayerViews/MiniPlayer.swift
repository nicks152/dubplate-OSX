import SwiftUI
import DubplateCore
import DubplateAudio

/// The strip that says something is playing.
///
/// Present on both platforms, sized differently: a toolbar-height bar on the Mac,
/// a floating pill above the tab bar on iPhone. Tapping it opens the player.
public struct MiniPlayer: View {
    public enum Style {
        case bar
        case floating
    }

    private let player: PlayerController
    private let artwork: ArtworkAsset?
    private let style: Style
    private let onOpen: () -> Void

    public init(
        player: PlayerController,
        artwork: ArtworkAsset?,
        style: Style = .bar,
        onOpen: @escaping () -> Void
    ) {
        self.player = player
        self.artwork = artwork
        self.style = style
        self.onOpen = onOpen
    }

    public var body: some View {
        if let item = player.currentItem {
            content(item)
                .background(background)
                .overlay(alignment: .top) {
                    if style == .bar {
                        Rectangle()
                            .fill(DubplateColor.hairline)
                            .frame(height: DubplateLayout.hairline)
                    }
                }
                .overlay(alignment: .bottom) {
                    if style == .floating {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(DubplateColor.playerPrimaryText.opacity(0.55))
                                .frame(width: geometry.size.width * player.progress, height: 2)
                        }
                        .frame(height: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: style == .floating ? 12 : 0, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Now playing: \(item.title) by \(item.artistName)")
                .accessibilityHint("Opens the player")
        }
    }

    private func content(_ item: PlaybackQueueItem) -> some View {
        HStack(spacing: DubplateLayout.m) {
            ArtworkView(asset: artwork, title: item.releaseTitle, cornerRadius: 4)
                .frame(width: style == .bar ? 30 : 40, height: style == .bar ? 30 : 40)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Text(item.artistName)
                    .font(DubplateType.metadata)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: DubplateLayout.s)

            if style == .bar {
                Text("\(Formatting.duration(player.displayTime)) / \(Formatting.duration(player.duration))")
                    .font(DubplateType.metadata)
                    .foregroundStyle(secondaryTextColor)
            }

            TransportControls(
                player: player,
                size: .compact,
                showsModes: false,
                tint: textColor
            )
        }
        .padding(.horizontal, DubplateLayout.m)
        .frame(height: style == .bar ? 52 : 62)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .bar:
            DubplateColor.raised
        case .floating:
            DubplateColor.playerGround.opacity(0.94)
        }
    }

    private var textColor: Color {
        style == .bar ? DubplateColor.primaryText : DubplateColor.playerPrimaryText
    }

    private var secondaryTextColor: Color {
        style == .bar ? DubplateColor.tertiaryText : DubplateColor.playerSecondaryText
    }
}
