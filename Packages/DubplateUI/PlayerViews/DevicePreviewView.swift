import SwiftUI
import DubplateCore
import DubplateAudio

/// A phone-sized window onto the record, shown on the Mac.
///
/// Not a simulator and not a mock-up of anyone's hardware: a plain 393 × 852 frame
/// with the real player inside it, so the layout, type and artwork can be judged at
/// the size they will actually be seen. Playback inside it is the same playback —
/// there is only one player in the process.
public struct DevicePreviewView: View {
    private let player: PlayerController
    private let artwork: ArtworkAsset?
    private let canvasURL: URL?
    @Binding private var mode: PreviewMode

    /// iPhone 15/16 logical size. Fixed on purpose: previewing at an arbitrary size
    /// would defeat the point.
    private static let phoneSize = CGSize(width: 393, height: 852)

    public init(
        player: PlayerController,
        artwork: ArtworkAsset?,
        canvasURL: URL? = nil,
        mode: Binding<PreviewMode>
    ) {
        self.player = player
        self.artwork = artwork
        self.canvasURL = canvasURL
        self._mode = mode
    }

    public var body: some View {
        VStack(spacing: DubplateLayout.l) {
            PreviewModePicker(mode: $mode)

            GeometryReader { geometry in
                let scale = min(
                    1,
                    min(
                        geometry.size.width / Self.phoneSize.width,
                        geometry.size.height / Self.phoneSize.height
                    )
                )
                NowPlayingView(
                    player: player,
                    artwork: artwork,
                    canvasURL: canvasURL,
                    mode: $mode,
                    showsModePicker: false
                )
                .frame(width: Self.phoneSize.width, height: Self.phoneSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 44, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            Text(mode.explanation)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .padding(DubplateLayout.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DubplateColor.ground)
        .accessibilityLabel("Phone preview, \(mode.displayName) mode")
    }
}
