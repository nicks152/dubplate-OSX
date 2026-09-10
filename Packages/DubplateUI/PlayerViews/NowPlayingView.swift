import SwiftUI
import DubplateCore
import DubplateAudio

/// The player.
///
/// One container, three presentations. Switching between them is a horizontal
/// gesture or a control, and it never interrupts the audio — the whole point is to
/// hear the same moment presented three ways.
public struct NowPlayingView: View {
    private let player: PlayerController
    private let artwork: ArtworkAsset?
    private let canvas: MotionSource?
    @Binding private var mode: PreviewMode
    private let showsModePicker: Bool
    private let onShowVersions: (() -> Void)?
    private let onShowQueue: (() -> Void)?
    private let onDismiss: (() -> Void)?

    public init(
        player: PlayerController,
        artwork: ArtworkAsset?,
        canvas: MotionSource? = nil,
        mode: Binding<PreviewMode>,
        showsModePicker: Bool = true,
        onShowVersions: (() -> Void)? = nil,
        onShowQueue: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.player = player
        self.artwork = artwork
        self.canvas = canvas
        self._mode = mode
        self.showsModePicker = showsModePicker
        self.onShowVersions = onShowVersions
        self.onShowQueue = onShowQueue
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            DubplateColor.playerGround.ignoresSafeArea()

            Group {
                switch mode {
                case .stream:
                    StreamModeView(player: player, artwork: artwork, onShowVersions: onShowVersions, onShowQueue: onShowQueue)
                case .gallery:
                    GalleryModeView(player: player, artwork: artwork, onShowVersions: onShowVersions)
                case .motion:
                    MotionModeView(player: player, artwork: artwork, canvas: canvas, onShowVersions: onShowVersions)
                }
            }
            .transition(.opacity)

            if showsModePicker {
                VStack {
                    Spacer()
                    PreviewModePicker(mode: $mode)
                        .padding(.bottom, DubplateLayout.l)
                }
            }
        }
        .animation(DubplateMotion.expressive, value: mode)
        .overlay(alignment: .topLeading) {
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                        .frame(width: DubplateLayout.minimumTapTarget, height: DubplateLayout.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .padding(DubplateLayout.s)
                .accessibilityLabel("Close player")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let modes = PreviewMode.allCases
                    guard let index = modes.firstIndex(of: mode) else { return }
                    let offset = value.translation.width < 0 ? 1 : -1
                    let next = (index + offset + modes.count) % modes.count
                    mode = modes[next]
                }
        )
    }
}

/// The segmented control that switches presentation.
public struct PreviewModePicker: View {
    @Binding private var mode: PreviewMode

    public init(mode: Binding<PreviewMode>) {
        self._mode = mode
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(PreviewMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Text(option.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .kerning(0.3)
                        .padding(.horizontal, DubplateLayout.m)
                        .frame(height: 26)
                        .background(
                            Capsule().fill(mode == option ? Color.white.opacity(0.16) : .clear)
                        )
                        .foregroundStyle(
                            mode == option ? DubplateColor.playerPrimaryText : DubplateColor.playerSecondaryText
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
                .accessibilityHint(option.explanation)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
}
