import SwiftUI
import AppKit
import DubplateCore
import DubplateUI

/// "Show in Finder".
///
/// Dubplate keeps its own copy of every bounce, so this reveals the copy, not the
/// producer's original — which is deliberate: the file in their bounce folder is
/// theirs to move, rename or delete without breaking a record.
enum RevealInFinder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Search results across the whole library.
struct MacSearchResultsView: View {
    let query: String
    let onOpen: (UUID) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DubplateLayout.l) {
                if results.isEmpty {
                    EmptyState(
                        headline: "Nothing matches “\(query)”",
                        message: "Search looks at release names, track names, artists and the original filenames."
                    )
                } else {
                    ForEach(results) { result in
                        Button {
                            if let releaseID = result.releaseID { onOpen(releaseID) }
                        } label: {
                            HStack(spacing: DubplateLayout.m) {
                                Text(kindLabel(result.kind))
                                    .dubplateLabelStyle()
                                    .frame(width: 56, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.title)
                                        .dubplateFont(DubplateType.rowTitle)
                                        .foregroundStyle(DubplateColor.primaryText)
                                    Text(result.subtitle)
                                        .dubplateFont(DubplateType.metadata)
                                        .foregroundStyle(DubplateColor.tertiaryText)
                                }
                                Spacer()
                            }
                            .padding(.vertical, DubplateLayout.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(DubplateColor.hairline)
                    }
                }
            }
            .padding(DubplateLayout.xxl)
        }
        .background(DubplateColor.ground)
    }

    private func kindLabel(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .release: return "Release"
        case .track: return "Track"
        case .version: return "Mix"
        }
    }

    private var results: [SearchResult] {
        LibrarySearch.run(query: query, over: LibraryIndexing.entries(for: library))
    }
}

/// Loose tracks that are not on a record yet.
struct InboxScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @Environment(\.modelContext) private var context
    @State private var isTargeted = false
    @State private var selection: UUID?
    @State private var trackToFile: Track?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                Text("Inbox")
                    .dubplateDisplayStyle(.screen)
                    .foregroundStyle(DubplateColor.primaryText)
                Text("Ideas and loose bounces that aren’t on a record yet.")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
            .padding(DubplateLayout.xxl)

            let tracks = library.inboxTracks()
            if tracks.isEmpty {
                EmptyState(
                    headline: "Inbox is empty",
                    message: "Drop a bounce here when you want to hear it back without deciding what record it belongs to. Right-click one later to file it."
                )
            } else {
                TrackListView(
                    tracks: tracks,
                    currentTrackID: player.currentItem?.trackID,
                    isPlaying: player.isPlaying,
                    playingVersionID: player.currentItem?.versionID,
                    selection: $selection,
                    allowsReordering: false,
                    onPlay: { services.play(track: $0) },
                    onRemove: { trackToFile = $0 },
                    onDelete: { services.delete(track: $0) }
                )
            }
        }
        .background(DubplateColor.ground)
        .overlay {
            if isTargeted { DropOverlay(message: "Add to Inbox") }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard DroppedFiles.couldHoldMedia(urls) else { return false }
            Task {
                let plan = await library.plan(for: urls, in: nil)
                let outcome = await library.apply(plan, to: nil)
                services.report(outcome)
                await services.registerNewMedia(in: nil)
            }
            return true
        } isTargeted: { isTargeted = $0 }
        // The Inbox used to be a room with no exit: you could put a bounce in and
        // never decide what record it belonged to.
        .confirmationDialog(
            trackToFile.map { "Add “\($0.displayTitle)” to a release" } ?? "",
            isPresented: Binding(get: { trackToFile != nil }, set: { if !$0 { trackToFile = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(library.releases()) { release in
                Button(release.title.isEmpty ? "Untitled" : release.title) {
                    if let track = trackToFile {
                        library.move(track: track, to: release)
                    }
                    trackToFile = nil
                }
            }
            Button("Cancel", role: .cancel) { trackToFile = nil }
        }
    }
}

/// Settings.
struct MacSettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(DubplateSettings.self) private var settings
    @Environment(SyncCoordinator.self) private var sync

    @State private var storageUsed: Int64 = 0

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("iCloud") {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { settings.syncEnabled },
                    set: { newValue in
                        settings.syncEnabled = newValue
                        sync.setEnabled(newValue)
                    }
                ))
                if let explanation = sync.accountState.explanation {
                    Text(explanation.title)
                        .dubplateFont(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.secondaryText)
                }
                Button("Sync Now") {
                    Task { await sync.syncNow() }
                }
                .disabled(!settings.syncEnabled || !sync.accountState.canSync)
            }

            Section("Audio") {
                Toggle("Measure loudness", isOn: $settings.measuresLoudness)
                Text("Reads each file once to show its LUFS. Dubplate never changes your audio.")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(DubplateSettings.Appearance.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }

            Section("Preview") {
                Picker("Opens in", selection: $settings.defaultPreviewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Which way the iPhone preview starts. You can still swipe between all three.")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }

            Section("Storage") {
                LabeledContent("Media on this Mac", value: Formatting.fileSize(storageUsed))
                Button("Show in Finder") {
                    RevealInFinder.reveal(services.mediaStore.root)
                }
            }

            Section("About") {
                Text(DubplateSettings.audioPolicy)
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task {
            let store = services.mediaStore
            storageUsed = await Task.detached { store.usedBytes() }.value
        }
    }
}
