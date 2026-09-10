import SwiftUI
import DubplateCore
import DubplateAudio

/// Previous, play/pause, next — plus shuffle and repeat where there is room.
public struct TransportControls: View {
    public enum Size {
        case compact
        case regular
        case large

        var playDiameter: CGFloat {
            switch self {
            case .compact: return 34
            case .regular: return 52
            case .large: return 68
            }
        }

        var glyph: CGFloat {
            switch self {
            case .compact: return 13
            case .regular: return 20
            case .large: return 26
            }
        }

        /// Every control carries the same outer frame, so the frames provide the
        /// optical gap and the spacing between them is small.
        var frame: CGFloat {
            switch self {
            case .compact: return 44
            case .regular: return 52
            case .large: return 68
            }
        }

        var spacing: CGFloat {
            switch self {
            case .compact: return DubplateLayout.xs
            case .regular: return DubplateLayout.m
            case .large: return DubplateLayout.xl
            }
        }
    }

    private let player: PlayerController
    private let size: Size
    private let showsModes: Bool
    private let tint: Color

    public init(
        player: PlayerController,
        size: Size = .regular,
        showsModes: Bool = true,
        tint: Color = DubplateColor.playerPrimaryText
    ) {
        self.player = player
        self.size = size
        self.showsModes = showsModes
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: size.spacing) {
            if showsModes {
                modeButton(
                    systemName: "shuffle",
                    isOn: player.isShuffled,
                    label: player.isShuffled ? "Turn shuffle off" : "Shuffle"
                ) {
                    player.setShuffled(!player.isShuffled)
                }
            }

            button(systemName: "backward.fill", label: "Previous track", size: size.glyph) {
                player.previous()
            }

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .dubplateFont(.fixed(size.glyph, weight: .medium))
                        .foregroundStyle(DubplateColor.playerGround)
                        // Optical centring: a play triangle sits left of true centre.
                        .offset(x: player.isPlaying ? 0 : size.glyph * 0.06)
                }
                .frame(width: size.playDiameter, height: size.playDiameter)
                .frame(width: size.frame, height: size.frame)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            button(systemName: "forward.fill", label: "Next track", size: size.glyph) {
                player.next()
            }

            if showsModes {
                modeButton(
                    systemName: player.repeatMode == .one ? "repeat.1" : "repeat",
                    isOn: player.repeatMode != .off,
                    label: repeatLabel
                ) {
                    player.cycleRepeatMode()
                }
            }
        }
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat one"
        case .one: return "Turn repeat off"
        }
    }

    private func button(systemName: String, label: String, size glyphSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .dubplateFont(.fixed(glyphSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size.frame, height: size.frame)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func modeButton(systemName: String, isOn: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .dubplateFont(.fixed(14, weight: .medium))
                .foregroundStyle(isOn ? tint : tint.opacity(0.42))
                .frame(minWidth: DubplateLayout.minimumTapTarget, minHeight: DubplateLayout.minimumTapTarget)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Buttons dip very slightly under a press. Enough to feel, not enough to notice.
public struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(DubplateMotion.respecting(reduceMotion, DubplateMotion.quick), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
