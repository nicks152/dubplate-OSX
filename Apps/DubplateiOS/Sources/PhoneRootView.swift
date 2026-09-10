import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// The phone.
///
/// Two places — the library and search — a mini player, and the record itself.
/// There is no import screen, no sync screen and no file browser, because the
/// phone's job is listening.
struct PhoneRootView: View {
    @Environment(AppServices.self) private var services
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var path = NavigationPath()
    @State private var isShowingPlayer = false
    @State private var previewMode: PreviewMode = .stream
    @State private var searchText = ""
    @State private var isImporting = false

    var body: some View {
        NavigationStack(path: $path) {
            PhoneHomeScreen(path: $path, searchText: $searchText, isImporting: $isImporting)
                .navigationDestination(for: UUID.self) { releaseID in
                    if let release = library.release(id: releaseID) {
                        PhoneReleaseScreen(release: release)
                    } else {
                        EmptyState(
                            headline: "That release is gone",
                            message: "It may have been deleted on another device."
                        )
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer(
                player: player,
                artwork: currentArtwork,
                style: .floating,
                onOpen: { isShowingPlayer = true }
            )
            .padding(.horizontal, DubplateLayout.m)
            .padding(.bottom, DubplateLayout.s)
        }
        .fullScreenCover(isPresented: $isShowingPlayer) {
            PhonePlayerScreen(mode: $previewMode, onDismiss: { isShowingPlayer = false })
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await importToInbox(urls) }
        }
        .overlay(alignment: .bottom) {
            if let error = library.lastError ?? player.lastError ?? services.startupNotice {
                ErrorBanner(error: error) {
                    library.lastError = nil
                    player.clearError()
                    services.dismissStartupNotice()
                }
                .padding(DubplateLayout.l)
                .padding(.bottom, 88)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DubplateMotion.standard, value: library.lastError?.id)
        .onAppear { previewMode = services.settings.defaultPreviewMode }
    }

    private var currentArtwork: ArtworkAsset? {
        guard let releaseID = player.currentItem?.releaseID else { return nil }
        return library.release(id: releaseID)?.artwork
    }

    /// Files brought in on the phone land in the Inbox rather than guessing which
    /// record they belong to.
    private func importToInbox(_ urls: [URL]) async {
        let plan = library.plan(for: urls, in: nil)
        await library.apply(plan, to: nil)
        await services.registerNewMedia(in: nil)
    }
}
