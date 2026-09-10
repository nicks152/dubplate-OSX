import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import DubplateCore
import DubplateUI

/// A record, open.
///
/// Header, sequence, and — when a track is selected — the inspector. Bounces get
/// dropped anywhere on this screen: onto a track to make a new version of it, onto
/// the empty space to add to the record.
struct ReleaseDetailScreen: View {
    let release: Release

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var selectedTrackID: UUID?
    @State private var isTargeted = false
    @State private var pendingPlan: ImportPlan?
    @State private var pendingDrop: (track: Track, url: URL, match: VersionMatch?)?
    @State private var versionsTrack: Track?
    @State private var isImporting = false
    @State private var isChoosingArtwork = false

    var body: some View {
        HSplitView {
            main
            if let track = selectedTrack {
                TrackInspectorView(
                    track: track,
                    onCommit: { library.save() },
                    onShowVersions: { versionsTrack = track }
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(DubplateMotion.standard, value: selectedTrackID)
        .background(DubplateColor.ground)
        .onAppear { services.open(release: release) }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                DropOverlay(message: "Add to \(release.title)")
            }
        }
        .overlay(alignment: .top) {
            if let progress = library.importProgress {
                ImportProgressBar(progress: progress)
                    .padding(DubplateLayout.l)
            }
        }
        .sheet(item: Binding(get: { pendingPlan.map(IdentifiedPlan.init) }, set: { _ in pendingPlan = nil })) { wrapper in
            ImportPlanSheet(
                plan: wrapper.plan,
                releaseTitle: release.title,
                onCancel: { pendingPlan = nil },
                onConfirm: { plan in
                    pendingPlan = nil
                    Task { await apply(plan) }
                }
            )
        }
        .sheet(item: Binding(get: { versionsTrack }, set: { versionsTrack = $0 })) { track in
            VersionsSheet(track: track) { versionsTrack = nil }
        }
        .sheet(isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } })) {
            if let drop = pendingDrop {
                TrackDropSheet(
                    filename: drop.url.lastPathComponent,
                    track: drop.track,
                    suggestion: drop.match,
                    onCancel: { pendingDrop = nil },
                    onChoose: { choice in
                        pendingDrop = nil
                        Task { await applyDrop(choice: choice, url: drop.url, track: drop.track) }
                    }
                )
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, .mpeg4Audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                _ = handleDrop(urls)
            }
        }
        .fileImporter(
            isPresented: $isChoosingArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await library.setArtwork(from: url, for: release)
                    services.artwork.invalidate(relativePath: release.artwork?.relativePath ?? "")
                    await services.registerNewMedia(in: release)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dubplateImportAudio)) { _ in
            isImporting = true
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReleaseHeaderView(
                release: release,
                layout: .horizontal,
                onPlay: { services.play(release: release) },
                onShuffle: { services.play(release: release, shuffled: true) },
                onEditArtwork: { isChoosingArtwork = true }
            )
            .padding(DubplateLayout.xxl)

            if release.trackCount == 0 {
                EmptyState(
                    headline: "No tracks yet",
                    message: "Drag your bounces in. Dubplate will read the numbers in the filenames and sequence them for you.",
                    actionTitle: "Import Audio…",
                    action: { isImporting = true }
                )
            } else {
                TrackListView(
                    tracks: release.orderedTracks,
                    currentTrackID: player.currentItem?.trackID,
                    isPlaying: player.isPlaying,
                    selection: $selectedTrackID,
                    onPlay: { services.play(release: release, startingAt: $0) },
                    onMove: { offsets, destination in
                        library.move(in: release, fromOffsets: offsets, toOffset: destination)
                    },
                    onDropAudio: { track, urls in
                        guard let url = urls.first else { return }
                        pendingDrop = (
                            track,
                            url,
                            VersionMatcher.match(
                                filename: url.lastPathComponent,
                                among: library.summaries(for: release)
                            )
                        )
                    },
                    onDelete: { library.delete(track: $0) }
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520)
    }

    private var selectedTrack: Track? {
        guard let selectedTrackID else { return nil }
        return release.orderedTracks.first { $0.id == selectedTrackID }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let images = urls.filter { FilenameParser.isImage($0.lastPathComponent) }
        let audio = urls.filter { FilenameParser.isAudio($0.lastPathComponent) }
        guard !images.isEmpty || !audio.isEmpty else { return false }

        Task {
            if let image = images.first {
                await library.setArtwork(from: image, for: release)
                services.artwork.invalidateAll()
            }
            if !audio.isEmpty {
                let plan = library.plan(for: audio, in: release)
                if ImportPlanSheet.requiresConfirmation(plan) {
                    pendingPlan = plan
                } else {
                    await apply(plan)
                }
            }
            await services.registerNewMedia(in: release)
        }
        return true
    }

    private func apply(_ plan: ImportPlan) async {
        await library.apply(plan, to: release)
        await services.registerNewMedia(in: release)
        for track in release.orderedTracks {
            services.refreshQueueEntry(for: track)
        }
    }

    private func applyDrop(choice: TrackDropChoice, url: URL, track: Track) async {
        await library.apply(choice: choice, url: url, to: track)
        await services.registerNewMedia(in: release)
        services.refreshQueueEntry(for: track)
    }
}

/// `sheet(item:)` needs something identifiable; a plan is a value.
struct IdentifiedPlan: Identifiable {
    let id = UUID()
    let plan: ImportPlan

    init(_ plan: ImportPlan) {
        self.plan = plan
    }
}

/// The bar that appears while files are being copied in.
struct ImportProgressBar: View {
    let progress: ImportProgress

    var body: some View {
        HStack(spacing: DubplateLayout.m) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text(progress.currentFilename)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(progress.completed) of \(progress.total)")
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
        }
        .padding(.horizontal, DubplateLayout.l)
        .padding(.vertical, DubplateLayout.m)
        .background(DubplateColor.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(DubplateColor.hairline))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .accessibilityLabel("Importing \(progress.currentFilename), \(progress.completed) of \(progress.total)")
    }
}

/// The version list, as a sheet from the release page.
struct VersionsSheet: View {
    let track: Track
    let onDismiss: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @State private var renaming: TrackVersion?
    @State private var draftLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xl) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Versions").dubplateLabelStyle()
                    Text(track.displayTitle)
                        .dubplateDisplayStyle(size: 22)
                        .foregroundStyle(DubplateColor.primaryText)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(DubplateQuietButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VersionListView(
                    track: track,
                    playingVersionID: player.currentItem?.versionID,
                    onPlay: { services.audition(version: $0, of: track) },
                    onMakeCurrent: { version in
                        library.makeCurrent(version: version, of: track)
                        services.refreshQueueEntry(for: track)
                    },
                    onRename: { version in
                        renaming = version
                        draftLabel = version.label ?? ""
                    },
                    onDelete: { library.delete(version: $0) },
                    onReveal: { version in
                        guard let path = version.audioAsset?.relativePath else { return }
                        RevealInFinder.reveal(services.mediaStore.url(forRelativePath: path))
                    }
                )
            }
            .frame(maxHeight: 420)
        }
        .padding(DubplateLayout.xxl)
        .frame(width: 620)
        .background(DubplateColor.raised)
        .alert("Rename Version", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label", text: $draftLabel)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let version = renaming {
                    library.rename(version: version, to: draftLabel)
                }
                renaming = nil
            }
        } message: {
            Text("What do you call this mix?")
        }
    }
}
