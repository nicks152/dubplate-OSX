import SwiftUI
import SwiftData
import DubplateAudio
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

    /// A form that survives a relaunch. Deliberately not `Codable`: this is two
    /// lines, and a release that has since been deleted has to fail to restore
    /// rather than open an empty screen.
    var storageValue: String {
        switch self {
        case .recentlyPlayed: return "recentlyPlayed"
        case .albums: return "albums"
        case .eps: return "eps"
        case .singles: return "singles"
        case .projects: return "projects"
        case .inbox: return "inbox"
        case .release(let id): return "release:\(id.uuidString)"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "recentlyPlayed": self = .recentlyPlayed
        case "albums": self = .albums
        case "eps": self = .eps
        case "singles": self = .singles
        case "projects": self = .projects
        case "inbox": self = .inbox
        default:
            guard storageValue.hasPrefix("release:"),
                  let id = UUID(uuidString: String(storageValue.dropFirst("release:".count)))
            else {
                return nil
            }
            self = .release(id)
        }
    }

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

    // Restored across launches, so the window comes back to the record that was
    // open rather than always to Albums.
    @SceneStorage("dubplate.section") private var storedSection: String = ""
    @State private var section: LibrarySection = .albums
    @State private var isShowingNewRelease = false
    @State private var isShowingStorageHelp = false
    @State private var openedFiles: [URL] = []
    @State private var openedFilesTask: Task<Void, Never>?
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
                if services.downloadBlockedByCellular {
                    Toast(message: "Waiting for Wi-Fi. Turn on downloads over cellular to fetch this now.") {
                        services.downloadBlockedByCellular = false
                    }
                }
                // The Mac holds for a download exactly as the phone does — a
                // record made on one Mac and opened on another is the same
                // situation — and used to do it in complete silence, looking as
                // though the play button had not registered.
                if let waiting = player.awaitingDownloadOf {
                    Toast(message: "Downloading “\(waiting.title)” — it’ll start in a moment") {
                        player.abandonPendingItem()
                    }
                }
                if let error = visibleError {
                    ErrorBanner(
                        error: error,
                        onRetry: services.retryAction(for: error),
                        onDismiss: services.clearErrors
                    )
                }
            }
            .padding(DubplateLayout.xl)
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(DubplateMotion.standard, value: library.lastError?.id)
        .animation(DubplateMotion.standard, value: services.lastImportSummary)
        .animation(DubplateMotion.standard, value: player.awaitingDownloadOf?.id)
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
        .onAppear {
            if let restored = LibrarySection(storageValue: storedSection) {
                section = restored
            }
        }
        .onChange(of: section) { _, newValue in
            storedSection = newValue.storageValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .dubplateShowStorageHelp)) { _ in
            isShowingStorageHelp = true
        }
        // Dubplate appears in Finder's Open With for every bounce on the machine.
        // It used to appear there and then do nothing when chosen, which is worse
        // than not appearing at all. One notification per file, so they are
        // collected for a moment and imported as the single drop they are.
        .onOpenURL { url in
            openedFiles.append(url)
            openedFilesTask?.cancel()
            openedFilesTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let batch = openedFiles
                openedFiles.removeAll()
                await importOpened(batch)
            }
        }
        .alert("Where your bounces live", isPresented: $isShowingStorageHelp) {
            Button("Show in Finder") { RevealInFinder.reveal(services.mediaStore.root) }
            Button("Done", role: .cancel) {}
        } message: {
            Text(
                "Dubplate copies every bounce into its own folder and never touches "
                + "the file you dragged in. Your originals stay exactly where they "
                + "are, under whatever name you gave them.\n\n"
                + "With iCloud on, those copies sync to your other devices through "
                + "your own private iCloud. Nothing is uploaded anywhere else, "
                + "nothing is published, and no one but you can reach it."
            )
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

    /// Files chosen in Finder go where a drop of the same files would: into the
    /// release that is open, or into a new one named after their folder.
    private func importOpened(_ urls: [URL]) async {
        guard DroppedFiles.couldHoldMedia(urls) else { return }
        let openRelease: Release? = {
            guard case .release(let id) = section else { return nil }
            return library.release(id: id)
        }()

        let plan = await library.plan(for: urls, in: openRelease)
        guard !plan.isEmpty else {
            services.announce("Nothing in that Dubplate can play")
            return
        }
        let target = openRelease ?? library.createRelease(
            title: DroppedFiles.releaseName(from: urls) ?? "",
            artistName: library.defaultArtistName,
            type: ReleaseType.inferred(fromTrackCount: plan.audioFileCount)
        )
        let outcome = await library.apply(plan, to: target)
        services.report(outcome)
        await services.registerNewMedia(in: target)
        section = .release(target.id)
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
            let plan = await library.plan(for: result.audioURLs, in: release)
            let outcome = await library.apply(plan, to: release)
            services.report(outcome)
        }
        await services.registerNewMedia(in: release)
        section = .release(release.id)
    }
}
