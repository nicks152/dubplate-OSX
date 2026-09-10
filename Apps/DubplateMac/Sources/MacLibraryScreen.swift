import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// The shelf: every record, artwork first.
struct MacLibraryScreen: View {
    let section: LibrarySection
    let onOpen: (Release) -> Void

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Query(sort: \Release.updatedAt, order: .reverse) private var allReleases: [Release]

    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DubplateLayout.xl) {
                header

                if releases.isEmpty {
                    EmptyState(
                        headline: emptyHeadline,
                        message: "Drop a folder of bounces here, or make a release and drag the audio in.",
                        actionTitle: "New Release",
                        action: { NotificationCenter.default.post(name: .dubplateNewRelease, object: nil) }
                    )
                    .frame(minHeight: 320)
                } else {
                    LibraryGrid(
                        releases: releases,
                        playingReleaseID: player.currentItem?.releaseID,
                        onOpen: onOpen,
                        onPlay: { services.play(release: $0) }
                    )
                }
            }
            .padding(DubplateLayout.xxl)
        }
        .background(DubplateColor.ground)
        .overlay {
            if isTargeted {
                DropOverlay(message: "Drop bounces to start a new release")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { FilenameParser.isAudio($0.lastPathComponent) }
            guard !audio.isEmpty else { return false }
            Task { await createRelease(from: audio) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xs) {
            Text(section.title)
                .dubplateDisplayStyle(size: 30)
                .foregroundStyle(DubplateColor.primaryText)
            Text(subtitle)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
        }
    }

    private var subtitle: String {
        let count = releases.count
        guard count > 0 else { return "Nothing here yet" }
        return "\(count) release\(count == 1 ? "" : "s")"
    }

    private var emptyHeadline: String {
        switch section {
        case .recentlyPlayed: return "Nothing played yet"
        default: return "No records yet"
        }
    }

    private var releases: [Release] {
        switch section {
        case .recentlyPlayed:
            return allReleases
                .filter { $0.lastPlayedAt != nil }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .albums: return allReleases.filter { $0.releaseType == .album }
        case .eps: return allReleases.filter { $0.releaseType == .ep }
        case .singles: return allReleases.filter { $0.releaseType == .single }
        case .projects: return allReleases.filter { $0.releaseType.isShelvedUnderProjects }
        case .inbox, .release: return allReleases
        }
    }

    /// A folder dropped on the library becomes a record named after the folder.
    private func createRelease(from urls: [URL]) async {
        let folderName = urls.first?.deletingLastPathComponent().lastPathComponent ?? "New Release"
        let release = library.createRelease(
            title: folderName,
            artistName: library.defaultArtistName,
            type: ReleaseType.inferred(fromTrackCount: urls.count)
        )
        let plan = library.plan(for: urls, in: release)
        await library.apply(plan, to: release)
        await services.registerNewMedia(in: release)
        onOpen(release)
    }
}

/// The sheet of colour that appears under a drag.
struct DropOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            DubplateColor.ground.opacity(0.86)
            VStack(spacing: DubplateLayout.s) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 28, weight: .light))
                Text(message)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(DubplateColor.primaryText)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DubplateLayout.sheetRadius, style: .continuous)
                .strokeBorder(DubplateColor.accent.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .padding(DubplateLayout.l)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
