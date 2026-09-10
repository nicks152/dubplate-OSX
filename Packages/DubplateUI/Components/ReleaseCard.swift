import SwiftUI
import DubplateCore

/// A record in the library grid.
///
/// Artwork first, then two quiet lines. The play affordance only appears on hover
/// (Mac) or long press (iPhone) so that a wall of covers stays a wall of covers.
public struct ReleaseCard: View {
    private let release: Release
    private let isPlaying: Bool
    /// A paused record must stop dancing in the grid.
    private let isAnimatingIndicator: Bool
    private let onPlay: (() -> Void)?
    /// On a phone there is no hover, so the affordance has to be there.
    #if os(iOS)
    private let alwaysShowsPlay = true
    #else
    private let alwaysShowsPlay = false
    #endif

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        release: Release,
        isPlaying: Bool = false,
        isAnimatingIndicator: Bool = false,
        onPlay: (() -> Void)? = nil
    ) {
        self.release = release
        self.isPlaying = isPlaying
        self.isAnimatingIndicator = isAnimatingIndicator
        self.onPlay = onPlay
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.m) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(asset: release.artwork, title: release.title, artist: release.artistName)
                    .overlay {
                        // A shadow at 0.16 black is invisible on a near-black ground;
                        // on a dark shelf, hover is a light edge.
                        RoundedRectangle(cornerRadius: DubplateLayout.artworkRadius, style: .continuous)
                            .strokeBorder(.white.opacity(isHovering ? 0.32 : 0), lineWidth: 1)
                    }

                if let onPlay, isHovering || alwaysShowsPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DubplateColor.playerPrimaryText)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .padding(DubplateLayout.m)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityLabel("Play \(release.title)")
                    .opacity(alwaysShowsPlay && !isHovering ? 0.9 : 1)
                }
            }

            // Two lines. A third — "Album · 8 tracks" — is what turns a wall of
            // covers into a directory listing, and the release page already says it.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DubplateLayout.xs) {
                    if isPlaying {
                        PlayingIndicator(isAnimating: isAnimatingIndicator)
                    }
                    Text(release.title.isEmpty ? "Untitled" : release.title)
                        .font(DubplateType.cardTitle)
                        .foregroundStyle(DubplateColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(release.artistName)
                    .font(DubplateType.rowSubtitle)
                    .foregroundStyle(DubplateColor.secondaryText)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .animation(DubplateMotion.respecting(reduceMotion, DubplateMotion.quick), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(release.title), \(release.artistName), \(release.subtitleLine)")
    }
}

/// The three bars that say "this is the one playing".
///
/// They animate only while audio is actually moving, and not at all when the person
/// has asked for reduced motion — a permanently animating element in a list is
/// exhausting to sit next to.
public struct PlayingIndicator: View {
    private let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    public init(isAnimating: Bool = true) {
        self.isAnimating = isAnimating
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(DubplateColor.accent)
                    .frame(width: 2, height: height(for: index))
            }
        }
        .frame(width: 10, height: 10, alignment: .bottom)
        .onAppear {
            guard isAnimating, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        guard isAnimating, !reduceMotion else { return [6, 10, 7][index] }
        let base: [CGFloat] = [4, 10, 6]
        let peak: [CGFloat] = [10, 4, 9]
        return base[index] + (peak[index] - base[index]) * phase
    }
}
