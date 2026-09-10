import SwiftUI
import DubplateCore
import DubplateUI

/// The player, full screen.
struct PhonePlayerScreen: View {
    @Binding var mode: PreviewMode
    let onDismiss: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var isShowingQueue = false
    @State private var isShowingVersions = false

    var body: some View {
        NowPlayingView(
            player: player,
            artwork: currentArtwork,
            canvasURL: currentCanvasURL,
            mode: $mode,
            onShowVersions: { isShowingVersions = true },
            onShowQueue: { isShowingQueue = true },
            onDismiss: onDismiss
        )
        .sheet(isPresented: $isShowingQueue) {
            QueueView(player: player) { isShowingQueue = false }
                .presentationDetents([.medium, .large])
                .presentationBackground(DubplateColor.playerGround)
        }
        .sheet(isPresented: $isShowingVersions) {
            if let track = currentTrack {
                VersionPickerSheet(
                    track: track,
                    playingVersionID: player.currentItem?.versionID,
                    onSelect: { services.audition(version: $0, of: track) },
                    onSetCurrent: { version in
                        library.makeCurrent(version: version, of: track)
                        services.refreshQueueEntry(for: track)
                    },
                    onDismiss: { isShowingVersions = false }
                )
                .presentationDetents([.medium])
                .presentationBackground(DubplateColor.playerGround)
            } else {
                EmptyState(headline: "No versions", message: "This track only has one mix.")
            }
        }
    }

    private var currentTrack: Track? {
        guard let trackID = player.currentItem?.trackID else { return nil }
        return library.track(id: trackID)
    }

    private var currentArtwork: ArtworkAsset? {
        guard let releaseID = player.currentItem?.releaseID else { return nil }
        return library.release(id: releaseID)?.artwork
    }

    /// A track canvas wins over the release's motion artwork, the way a per-track
    /// visual should.
    private var currentCanvasURL: URL? {
        if let path = player.currentItem?.canvasRelativePath,
           services.mediaStore.exists(relativePath: path) {
            return services.mediaStore.url(forRelativePath: path)
        }
        guard let releaseID = player.currentItem?.releaseID,
              let motion = library.release(id: releaseID)?.animatedArtwork,
              services.mediaStore.exists(relativePath: motion.relativePath)
        else {
            return nil
        }
        return services.mediaStore.url(forRelativePath: motion.relativePath)
    }
}

/// Settings on the phone: the same eight switches, in a list.
struct PhoneSettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(DubplateSettings.self) private var settings
    @Environment(SyncCoordinator.self) private var sync

    @State private var storageUsed: Int64 = 0

    var body: some View {
        @Bindable var settings = settings
        List {
            Section("iCloud") {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { settings.syncEnabled },
                    set: { newValue in
                        settings.syncEnabled = newValue
                        sync.setEnabled(newValue)
                    }
                ))
                if let explanation = sync.accountState.explanation {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(explanation.title).font(.system(size: 14))
                        Text(explanation.detail)
                            .font(DubplateType.metadata)
                            .foregroundStyle(DubplateColor.tertiaryText)
                    }
                }
                if sync.status.isWorthMentioning {
                    LabeledContent("Status", value: sync.status.label)
                }
            }

            Section("Downloads") {
                Toggle("Download over cellular", isOn: $settings.allowsCellularDownloads)
                Text("An album is often more than a gigabyte. With this off, Dubplate waits for Wi-Fi.")
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(DubplateSettings.Appearance.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Picker("Default Preview", selection: $settings.defaultPreviewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Music on this iPhone", value: Formatting.fileSize(storageUsed))
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Text(DubplateSettings.audioPolicy)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
                Text("Dubplate keeps your unreleased music private. Nothing leaves your devices except through your own iCloud account.")
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = services.mediaStore
            storageUsed = await Task.detached { store.usedBytes() }.value
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
