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

    var body: some View {
        NavigationStack(path: $path) {
            PhoneHomeScreen(path: $path, searchText: $searchText)
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
        .overlay(alignment: .bottom) {
            VStack(spacing: DubplateLayout.s) {
                if services.downloadBlockedByCellular {
                    Toast(message: "Waiting for Wi-Fi. Turn on cellular downloads in Settings to fetch this now.") {
                        services.downloadBlockedByCellular = false
                    }
                }
                if let waiting = player.awaitingDownloadOf {
                    Toast(message: "Downloading “\(waiting.title)” — it’ll start in a moment") {
                        player.abandonPendingItem()
                    }
                }
                if let error = library.lastError ?? player.lastError ?? services.sync.lastError ?? services.startupNotice {
                    ErrorBanner(
                        error: error,
                        onRetry: services.retryAction(for: error),
                        onDismiss: services.clearErrors
                    )
                }
            }
            .padding(DubplateLayout.l)
            .padding(.bottom, 88)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(DubplateMotion.standard, value: library.lastError?.id)
        .onAppear { previewMode = services.settings.defaultPreviewMode }
    }

    private var currentArtwork: ArtworkAsset? {
        guard let releaseID = player.currentItem?.releaseID else { return nil }
        return library.release(id: releaseID)?.artwork
    }

}
