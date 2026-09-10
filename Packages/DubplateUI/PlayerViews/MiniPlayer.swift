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
                        // The Mac has no other scrubber outside the phone preview,
                        // and a producer listening back to a mix needs to get to
                        // 2:14 without opening anything.
                        SlimScrubber(player: player)
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
                // The hint promised a way in and there was none: a tap gesture is
                // not a button, so VoiceOver had nothing to activate.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(action: onOpen)
        }
    }

    private func content(_ item: PlaybackQueueItem) -> some View {
        HStack(spacing: DubplateLayout.m) {
            ArtworkView(asset: artwork, title: item.releaseTitle, cornerRadius: 4)
                .frame(width: style == .bar ? 30 : 40, height: style == .bar ? 30 : 40)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .dubplateFont(.fixed(13, weight: .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Text(item.artistName)
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: DubplateLayout.s)

            if style == .bar {
                Text("\(Formatting.duration(player.displayTime)) / \(Formatting.duration(player.duration))")
                    .dubplateFont(DubplateType.metadata)
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

/// A hairline across the top of the Mac's player bar that is also the scrubber.
///
/// Two points tall until the pointer is near it, then six. It replaces the hairline
/// rather than sitting next to it, so the bar does not grow a control.
struct SlimScrubber: View {
    let player: PlayerController

    @State private var isHovering = false
    @State private var isScrubbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(DubplateColor.hairline)
                Rectangle()
                    .fill(DubplateColor.primaryText.opacity(isHovering || isScrubbing ? 0.9 : 0.45))
                    .frame(width: max(0, geometry.size.width * player.progress))
            }
            .frame(height: isHovering || isScrubbing ? 6 : 2)
            .frame(height: 14, alignment: .top)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.width > 0, player.duration > 0 else { return }
                        let fraction = min(max(0, value.location.x / geometry.size.width), 1)
                        let time = Double(fraction) * player.duration
                        if isScrubbing {
                            player.updateScrub(to: time)
                        } else {
                            isScrubbing = true
                            player.beginScrub(at: time)
                        }
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        player.endScrub()
                    }
            )
        }
        .frame(height: 14)
        .animation(DubplateMotion.respecting(reduceMotion, DubplateMotion.quick), value: isHovering)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Formatting.duration(player.displayTime)) of \(Formatting.duration(player.duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 15
            switch direction {
            case .increment: player.seek(to: player.currentTime + step)
            case .decrement: player.seek(to: max(0, player.currentTime - step))
            @unknown default: break
            }
        }
    }
}
