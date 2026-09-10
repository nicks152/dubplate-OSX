import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// What the library is filtered to.
enum LibrarySection: Hashable {
    case recentlyPlayed
    case albums
    case eps
    case singles
    case projects
    case inbox
    case release(UUID)

    var title: String {
        switch self {
        case .recentlyPlayed: return "Recently Played"
        case .albums: return "Albums"
        case .eps: return "EPs"
        case .singles: return "Singles"
        case .projects: return "All Projects"
        case .inbox: return "Inbox"
        case .release: return ""
        }
    }
}

/// The window.
///
/// Sidebar, library, and — when a release is open — that release. There is no third
/// pane by default: the inspector slides in when a track is selected and goes away
/// when it is not, because most of the time the thing worth looking at is the
/// sequence.
struct MacRootView: View {
    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var section: LibrarySection = .albums
    @State private var isShowingNewRelease = false
    @State private var searchText = ""
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar(section: $section, isShowingNewRelease: $isShowingNewRelease)
                .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 300)
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .background(DubplateColor.ground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer(
                player: player,
                artwork: currentArtwork,
                style: .bar,
                onOpen: { openWindow(id: DubplateWindow.phonePreview) }
            )
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: DubplateLayout.s) {
                if let summary = services.lastImportSummary {
                    Toast(message: summary) { services.clearImportSummary() }
                }
                if let error = visibleError {
                    ErrorBanner(error: error) {
                        library.lastError = nil
                        player.clearError()
                        services.sync.clearError()
                        services.dismissStartupNotice()
                    }
                }
            }
            .padding(DubplateLayout.xl)
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(DubplateMotion.standard, value: library.lastError?.id)
        .animation(DubplateMotion.standard, value: services.lastImportSummary)
        .sheet(isPresented: $isShowingNewRelease) {
            NewReleaseSheet(
                defaultArtistName: library.defaultArtistName,
                onCancel: { isShowingNewRelease = false },
                onCreate: { result in
                    isShowingNewRelease = false
                    Task { await create(result) }
                }
            )
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search records, tracks and mixes")
        .onReceive(NotificationCenter.default.publisher(for: .dubplateNewRelease)) { _ in
            isShowingNewRelease = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dubplateTogglePreview)) { _ in
            openWindow(id: DubplateWindow.phonePreview)
        }
    }

    /// Set when a record has just been created from a folder drop, so the release
    /// page can put the cursor in the title — naming it is the first thing that
    /// turns the folder into a record, and the fast path never asked.
    @State private var releaseAwaitingTitle: UUID?

    @ViewBuilder
    private var detail: some View {
        if !searchText.isEmpty {
            MacSearchResultsView(query: searchText) { releaseID in
                section = .release(releaseID)
                searchText = ""
            }
        } else {
            switch section {
            case .release(let id):
                if let release = library.release(id: id) {
                    ReleaseDetailScreen(
                        release: release,
                        focusesTitleOnAppear: releaseAwaitingTitle == release.id
                    )
                    .id(release.id)
                    .focusedValue(\.selectedRelease, release.id)
                    .onAppear { releaseAwaitingTitle = nil }
                } else {
                    EmptyState(headline: "That release is gone", message: "It may have been deleted on another device.")
                }
            case .inbox:
                InboxScreen()
            default:
                MacLibraryScreen(
                    section: section,
                    onOpen: { release in section = .release(release.id) },
                    onCreatedFromDrop: { releaseAwaitingTitle = $0.id }
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SyncStatusLabel()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: DubplateWindow.phonePreview)
            } label: {
                Label("iPhone", systemImage: "iphone")
            }
            .help("See this record the way it will look on a phone")
        }
    }

    private var visibleError: DubplateError? {
        library.lastError ?? player.lastError ?? services.sync.lastError ?? services.startupNotice
    }

    private var currentArtwork: ArtworkAsset? {
        guard let releaseID = player.currentItem?.releaseID else { return nil }
        return library.release(id: releaseID)?.artwork
    }

    private func create(_ result: NewReleaseSheet.Result) async {
        let release = library.createRelease(
            title: result.title,
            artistName: result.artistName,
            type: result.type
        )
        if let artworkURL = result.artworkURL {
            await library.setArtwork(from: artworkURL, for: release)
        }
        if !result.audioURLs.isEmpty {
            let plan = library.plan(for: result.audioURLs, in: release)
            let outcome = await library.apply(plan, to: release)
            services.report(outcome)
        }
        await services.registerNewMedia(in: release)
        section = .release(release.id)
    }
}
