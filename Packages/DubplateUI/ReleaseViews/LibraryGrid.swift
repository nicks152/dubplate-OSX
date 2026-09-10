import SwiftUI
import DubplateCore

/// The shelf.
///
/// A responsive grid of covers, which is the library's default and — on the Mac —
/// usually its only view. Cards size themselves between a floor and a ceiling so
/// the grid never becomes either a wall of stamps or four enormous squares.
public struct LibraryGrid: View {
    private let releases: [Release]
    private let playingReleaseID: UUID?
    private let onOpen: (Release) -> Void
    private let onPlay: (Release) -> Void

    public init(
        releases: [Release],
        playingReleaseID: UUID? = nil,
        onOpen: @escaping (Release) -> Void,
        onPlay: @escaping (Release) -> Void
    ) {
        self.releases = releases
        self.playingReleaseID = playingReleaseID
        self.onOpen = onOpen
        self.onPlay = onPlay
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: DubplateLayout.gridMinimumCardWidth,
                    maximum: DubplateLayout.gridMaximumCardWidth
                ),
                spacing: DubplateLayout.gridSpacing,
                alignment: .top
            )
        ]
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: DubplateLayout.xxl) {
            ForEach(releases) { release in
                Button {
                    onOpen(release)
                } label: {
                    ReleaseCard(
                        release: release,
                        isPlaying: release.id == playingReleaseID,
                        onPlay: { onPlay(release) }
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A horizontal row of covers, used for "Recently Played".
public struct ReleaseShelf: View {
    private let releases: [Release]
    private let cardWidth: CGFloat
    private let onOpen: (Release) -> Void

    public init(releases: [Release], cardWidth: CGFloat = 148, onOpen: @escaping (Release) -> Void) {
        self.releases = releases
        self.cardWidth = cardWidth
        self.onOpen = onOpen
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DubplateLayout.l) {
                ForEach(releases) { release in
                    Button {
                        onOpen(release)
                    } label: {
                        VStack(alignment: .leading, spacing: DubplateLayout.s) {
                            ArtworkView(asset: release.artwork, title: release.title)
                                .frame(width: cardWidth, height: cardWidth)
                            Text(release.title.isEmpty ? "Untitled" : release.title)
                                .font(DubplateType.cardTitle)
                                .foregroundStyle(DubplateColor.primaryText)
                                .lineLimit(1)
                            Text(release.releaseType.displayName)
                                .font(DubplateType.metadata)
                                .foregroundStyle(DubplateColor.tertiaryText)
                        }
                        .frame(width: cardWidth, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}
