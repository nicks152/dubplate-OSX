import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// The shelf: every record, artwork first.
struct MacLibraryScreen: View {
    let section: LibrarySection
    let onOpen: (Release) -> Void
    /// Called when a record was created from a drop, so the window can put the
    /// cursor in its title.
    var onCreatedFromDrop: ((Release) -> Void)?

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
                        isPlaying: player.isPlaying,
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
            guard DroppedFiles.couldHoldMedia(urls) else { return false }
            Task { await createRelease(from: urls) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// No count line: "6 releases" is a row count from a database view, and the
    /// grid underneath already says how many there are.
    private var header: some View {
        Text(section.title)
            .dubplateDisplayStyle(.screen)
            .foregroundStyle(DubplateColor.primaryText)
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
    ///
    /// The cover comes with it: the plan routes images to the release's artwork, so
    /// a bounce folder that has the sleeve in it arrives complete. Nothing is
    /// created until the drop turns out to hold audio — an empty folder must not
    /// leave an empty record behind.
    private func createRelease(from urls: [URL]) async {
        let plan = await library.plan(for: urls, in: nil)
        guard !plan.isEmpty else {
            services.announce("Nothing to add — that folder has no audio in it")
            return
        }
        let release = library.createRelease(
            title: DroppedFiles.releaseName(from: urls) ?? "",
            artistName: library.defaultArtistName,
            type: ReleaseType.inferred(fromTrackCount: plan.audioFileCount)
        )
        let outcome = await library.apply(plan, to: release)
        services.report(outcome)
        await services.registerNewMedia(in: release)
        onCreatedFromDrop?(release)
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
                    .dubplateFont(.fixed(28, weight: .light))
                Text(message)
                    .dubplateFont(.fixed(15, weight: .medium))
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
