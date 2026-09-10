import SwiftUI
import DubplateCore
import DubplateAudio

/// Motion: the record as a moving image.
///
/// A looping visual fills the screen, the type sits on top of it, and the controls
/// fade out of the way. Where a track has no canvas and the release has no motion
/// artwork, the cover fills the screen with a slow drift rather than pretending
/// there is video — an honest fallback that still feels intentional.
public struct MotionModeView: View {
    private let player: PlayerController
    private let artwork: ArtworkAsset?
    private let canvas: MotionSource?
    private let onShowVersions: (() -> Void)?

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        player: PlayerController,
        artwork: ArtworkAsset?,
        canvas: MotionSource?,
        onShowVersions: (() -> Void)? = nil
    ) {
        self.player = player
        self.artwork = artwork
        self.canvas = canvas
        self.onShowVersions = onShowVersions
    }

    public var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.35), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: DubplateLayout.l) {
                Spacer()

                VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                    Text(player.currentItem?.releaseTitle ?? "")
                        .dubplateLabelStyle(.white.opacity(0.7))
                    Text(player.currentItem?.title ?? "")
                        .dubplateFont(.fixed(30, weight: .semibold))
                        .kerning(-0.7)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(player.currentItem?.artistName ?? "")
                        .dubplateFont(.fixed(15))
                        .foregroundStyle(.white.opacity(0.75))
                }

                if controlsVisible {
                    VStack(spacing: DubplateLayout.l) {
                        ScrubBar(
                            progress: player.progress,
                            elapsed: player.displayTime,
                            duration: player.duration,
                            peaks: player.currentItem?.waveformPeaks,
                            tint: .white,
                            onScrubStart: { player.beginScrub(at: $0) },
                            onScrubChange: { player.updateScrub(to: $0) },
                            onScrubEnd: { player.endScrub() }
                        )
                        HStack {
                            TransportControls(player: player, size: .regular, showsModes: false, tint: .white)
                            Spacer()
                            if let onShowVersions {
                                Button("Mixes", action: onShowVersions)
                                    .buttonStyle(.plain)
                                    .dubplateFont(.fixed(12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(DubplateLayout.xl)
            .padding(.bottom, DubplateLayout.xxxl)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DubplateMotion.quick) { controlsVisible.toggle() }
            if controlsVisible { scheduleHide() }
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    @ViewBuilder
    private var backdrop: some View {
        if let canvas {
            LoopingVideoView(
                url: canvas.url,
                startTime: canvas.loopStart,
                loopDuration: canvas.loopDuration
            )
        } else {
            DriftingArtwork(asset: artwork, title: player.currentItem?.releaseTitle ?? "", isAnimating: !reduceMotion)
        }
    }

    /// Controls get out of the way on their own, and come back on a tap.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(DubplateMotion.quick) { controlsVisible = false }
        }
    }
}

/// The cover, filling the screen, moving just enough to feel alive.
struct DriftingArtwork: View {
    let asset: ArtworkAsset?
    let title: String
    let isAnimating: Bool

    @State private var drift = false

    var body: some View {
        GeometryReader { geometry in
            ArtworkView(asset: asset, title: title, cornerRadius: 0)
                .frame(width: geometry.size.width * 1.25, height: geometry.size.width * 1.25)
                .position(
                    x: geometry.size.width / 2 + (drift ? 14 : -14),
                    y: geometry.size.height / 2 + (drift ? -18 : 18)
                )
                .onAppear {
                    guard isAnimating else { return }
                    withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
                        drift = true
                    }
                }
        }
        .clipped()
    }
}
