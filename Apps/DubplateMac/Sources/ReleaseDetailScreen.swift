import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import DubplateCore
import DubplateUI

/// A record, open.
///
/// Header, sequence, and an inspector that changes with what is selected. Bounces
/// get dropped anywhere: onto a track to make a new mix of it, onto the empty space
/// to add to the record, onto the artwork to change the cover.
///
/// The version list lives in the inspector rather than behind a sheet, because
/// comparing two mixes means pausing and scrubbing while you do it — and a modal
/// puts the transport out of reach at exactly the wrong moment.
struct ReleaseDetailScreen: View {
    let release: Release
    /// True when this record was just made from a folder drop and still has the
    /// folder's name.
    var focusesTitleOnAppear: Bool = false

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var selectedTrackID: UUID?
    @State private var inspector: InspectorMode = .track
    @State private var isTargeted = false
    @State private var pendingPlan: IdentifiedPlan?
    @State private var pendingDrop: PendingTrackDrop?
    @State private var pendingArtwork: URL?
    @State private var trackToDelete: Track?
    @State private var renamingVersion: TrackVersion?
    @State private var annotatingVersion: TrackVersion?
    @State private var draftText = ""
    @State private var isImporting = false
    @State private var isChoosingArtwork = false

    private enum InspectorMode {
        case track
        case versions
    }

    var body: some View {
        HSplitView {
            main
            if let track = selectedTrack {
                inspectorPane(for: track)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(DubplateMotion.standard, value: selectedTrackID)
        .animation(DubplateMotion.quick, value: inspector)
        .background(DubplateColor.ground)
        .onAppear { services.open(release: release) }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                DropOverlay(message: "Add to \(release.title.isEmpty ? "this release" : release.title)")
            }
        }
        .overlay(alignment: .top) {
            if let progress = library.importProgress {
                ImportProgressBar(progress: progress)
                    .padding(DubplateLayout.l)
            }
        }
        .sheet(item: $pendingPlan) { wrapper in
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
        .sheet(item: $pendingDrop) { drop in
            TrackDropSheet(
                filename: drop.summary,
                track: drop.track,
                suggestion: drop.match,
                onCancel: { pendingDrop = nil },
                onChoose: { choice in
                    pendingDrop = nil
                    Task { await applyDrop(choice: choice, urls: drop.urls, track: drop.track) }
                }
            )
        }
        .confirmationDialog(
            artworkPrompt,
            isPresented: Binding(get: { pendingArtwork != nil }, set: { if !$0 { pendingArtwork = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace Cover") {
                if let url = pendingArtwork { Task { await setArtwork(url, announcing: "Cover replaced") } }
                pendingArtwork = nil
            }
            Button("Cancel", role: .cancel) { pendingArtwork = nil }
        } message: {
            Text("The cover you have now is deleted from this Mac.")
        }
        .confirmationDialog(
            deleteTrackPrompt,
            isPresented: Binding(get: { trackToDelete != nil }, set: { if !$0 { trackToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Track", role: .destructive) {
                if let track = trackToDelete {
                    if selectedTrackID == track.id { selectedTrackID = nil }
                    services.delete(track: track)
                }
                trackToDelete = nil
            }
            Button("Cancel", role: .cancel) { trackToDelete = nil }
        } message: {
            Text("Deleted from this Mac and from iCloud. This can’t be undone.")
        }
        .alert("Rename Mix", isPresented: Binding(get: { renamingVersion != nil }, set: { if !$0 { renamingVersion = nil } })) {
            TextField("Label", text: $draftText)
            Button("Cancel", role: .cancel) { renamingVersion = nil }
            Button("Save") {
                if let version = renamingVersion { library.rename(version: version, to: draftText) }
                renamingVersion = nil
            }
        } message: {
            Text("What do you call this mix?")
        }
        .alert("Note", isPresented: Binding(get: { annotatingVersion != nil }, set: { if !$0 { annotatingVersion = nil } })) {
            TextField("Too much sub in the second chorus…", text: $draftText)
            Button("Cancel", role: .cancel) { annotatingVersion = nil }
            Button("Save") {
                if let version = annotatingVersion { library.annotate(version: version, notes: draftText) }
                annotatingVersion = nil
            }
        } message: {
            Text("Kept against this mix, so you know why you moved on from it.")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .folder],
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
                Task { await setArtwork(url) }
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
                isEditable: true,
                focusesTitleOnAppear: focusesTitleOnAppear,
                onPlay: { services.play(release: release) },
                onShuffle: { services.play(release: release, shuffled: true) },
                onEditArtwork: { isChoosingArtwork = true },
                onCommit: { library.save() }
            )
            .padding(DubplateLayout.xxl)

            if let warning = sampleRateWarning {
                SequenceWarning(message: warning)
                    .padding(.horizontal, DubplateLayout.xxl)
                    .padding(.bottom, DubplateLayout.s)
            }

            if release.trackCount == 0 {
                EmptyState(
                    headline: "No tracks yet",
                    message: "Drag your bounce folder in. Dubplate reads the numbers in the filenames and sequences it for you.",
                    actionTitle: "Import Audio…",
                    action: { isImporting = true }
                )
            } else {
                TrackListView(
                    tracks: release.orderedTracks,
                    currentTrackID: player.currentItem?.trackID,
                    isPlaying: player.isPlaying,
                    playingVersionID: player.currentItem?.versionID,
                    selection: $selectedTrackID,
                    onPlay: { services.play(release: release, startingAt: $0) },
                    onMove: { offsets, destination in
                        library.move(in: release, fromOffsets: offsets, toOffset: destination)
                    },
                    onDropAudio: { track, urls in receiveDrop(urls, on: track) },
                    onShowVersions: { track in
                        selectedTrackID = track.id
                        inspector = .versions
                    },
                    onRemove: { library.removeFromRelease(track: $0) },
                    onDelete: { trackToDelete = $0 }
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520)
    }

    @ViewBuilder
    private func inspectorPane(for track: Track) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DubplateLayout.xl) {
                inspectorTab("Track", mode: .track)
                inspectorTab("\(track.versionCount) mixes", mode: .versions)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DubplateLayout.l)
            .padding(.vertical, DubplateLayout.m)

            Divider().overlay(DubplateColor.hairline)

            switch inspector {
            case .track:
                TrackInspectorView(
                    track: track,
                    onCommit: { library.save() },
                    onShowVersions: { inspector = .versions }
                )
            case .versions:
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
                            draftText = version.label ?? ""
                            renamingVersion = version
                        },
                        onAnnotate: { version in
                            draftText = version.notes ?? ""
                            annotatingVersion = version
                        },
                        onDelete: { library.delete(version: $0) },
                        onReveal: { version in
                            guard let path = version.audioAsset?.relativePath else { return }
                            RevealInFinder.reveal(services.mediaStore.url(forRelativePath: path))
                        }
                    )
                    .padding(DubplateLayout.l)
                }
                .background(DubplateColor.raised)
            }
        }
        .background(DubplateColor.raised)
    }

    /// Two words and a rule, rather than a system segmented control rendered in the
    /// user's accent colour.
    private func inspectorTab(_ title: String, mode: InspectorMode) -> some View {
        Button {
            inspector = mode
        } label: {
            VStack(spacing: 5) {
                Text(title)
                    .dubplateLabelStyle(inspector == mode ? DubplateColor.primaryText : DubplateColor.tertiaryText)
                Rectangle()
                    .fill(inspector == mode ? DubplateColor.primaryText : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(inspector == mode ? .isSelected : [])
    }

    private var selectedTrack: Track? {
        guard let selectedTrackID else { return nil }
        return release.orderedTracks.first { $0.id == selectedTrackID }
    }

    /// The one pre-release problem a release simulator is uniquely able to catch.
    private var sampleRateWarning: String? {
        let tracks = release.orderedTracks
        guard tracks.count > 1 else { return nil }
        for index in 1..<tracks.count {
            guard let previous = tracks[index - 1].currentAsset?.format,
                  let current = tracks[index].currentAsset?.format,
                  previous.isKnown, current.isKnown,
                  !previous.isGaplessCompatible(with: current)
            else {
                continue
            }
            return "Track \(index + 1) is \(current.sampleRateSummary) after \(previous.sampleRateSummary). "
                + "That join won’t be gapless — re-bounce it to match."
        }
        return nil
    }

    private var artworkPrompt: String {
        guard let url = pendingArtwork else { return "" }
        return "Use “\(url.lastPathComponent)” as the cover?"
    }

    private var deleteTrackPrompt: String {
        guard let track = trackToDelete else { return "" }
        let mixes = track.versionCount
        return "Delete “\(track.displayTitle)” and its \(mixes) mix\(mixes == 1 ? "" : "es")?"
    }

    // MARK: - Drops

    private func receiveDrop(_ urls: [URL], on track: Track) {
        let files = DroppedFiles.expand(urls)
        if let video = files.first(where: { FilenameParser.isVideo($0.lastPathComponent) }) {
            // A vertical loop dropped on a track is that track's canvas.
            Task {
                await library.setCanvas(from: video, for: track)
                await services.registerNewMedia(in: release)
            }
            return
        }
        let audio = files.filter { FilenameParser.isAudio($0.lastPathComponent) }
        guard !audio.isEmpty else { return }

        let match = VersionMatcher.match(
            filename: audio[0].lastPathComponent,
            among: library.summaries(for: release)
        )
        // The thing a producer does forty times a day should not cost a modal. When
        // the bounce clearly belongs to the track it was dropped on, add it, make it
        // current, and play it — the sheet is for the ambiguous case.
        let isObvious = audio.count == 1 && (match?.trackID == track.id || match == nil)
        if isObvious {
            Task { await applyDrop(choice: .addAsNewVersion, urls: audio, track: track) }
        } else {
            pendingDrop = PendingTrackDrop(track: track, urls: audio, match: match)
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let files = DroppedFiles.expand(urls)
        let images = files.filter { FilenameParser.isImage($0.lastPathComponent) }
        let audio = files.filter { FilenameParser.isAudio($0.lastPathComponent) }
        let videos = files.filter { FilenameParser.isVideo($0.lastPathComponent) }
        guard !images.isEmpty || !audio.isEmpty || !videos.isEmpty else { return false }

        if let image = images.first {
            if release.artwork == nil {
                // Nothing can be lost, and this is the moment a folder becomes a
                // record. It should not be answered with a dialog about a filename.
                Task { await setArtwork(image, announcing: "Cover set") }
            } else {
                // Replacing deletes the old file, so that one asks.
                pendingArtwork = image
            }
        }
        if !audio.isEmpty || !videos.isEmpty {
            // Planning walks the drop and matches every bounce against the record,
            // so it happens off the main actor and the sheet appears when it is
            // ready. A drop handler has to answer immediately either way.
            Task {
                let plan = await library.plan(for: audio + videos, in: release)
                if ImportPlanSheet.requiresConfirmation(plan) {
                    pendingPlan = IdentifiedPlan(plan)
                } else {
                    await apply(plan)
                }
            }
        }
        return true
    }

    private func apply(_ plan: ImportPlan) async {
        let outcome = await library.apply(plan, to: release)
        services.report(outcome)
        await services.registerNewMedia(in: release)
        for track in release.orderedTracks {
            services.refreshQueueEntry(for: track)
        }
    }

    private func applyDrop(choice: TrackDropChoice, urls: [URL], track: Track) async {
        var outcome = ImportOutcome()
        for url in urls {
            let result = await library.apply(choice: choice, url: url, to: track)
            outcome.createdTracks.append(contentsOf: result.createdTracks)
            outcome.addedVersions.append(contentsOf: result.addedVersions)
            outcome.duplicateFilenames.append(contentsOf: result.duplicateFilenames)
            outcome.repairedFilenames.append(contentsOf: result.repairedFilenames)
            outcome.failures.append(contentsOf: result.failures)
        }
        services.report(outcome, trackTitle: track.displayTitle)
        await services.registerNewMedia(in: release)

        // The sheet's own copy says the new mix starts playing, so it has to.
        if let newest = track.currentVersion, !outcome.addedVersions.isEmpty {
            services.audition(version: newest, of: track)
        } else {
            services.refreshQueueEntry(for: track)
        }
    }

    private func setArtwork(_ url: URL, announcing message: String? = nil) async {
        await library.setArtwork(from: url, for: release)
        services.artwork.invalidateAll()
        await services.registerNewMedia(in: release)
        if let message { services.announce(message) }
    }
}

/// One or more bounces waiting on a decision about one track.
struct PendingTrackDrop: Identifiable {
    let id = UUID()
    let track: Track
    let urls: [URL]
    let match: VersionMatch?

    var summary: String {
        urls.count == 1
            ? urls[0].lastPathComponent
            : "\(urls.count) bounces"
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

/// A quiet line above the sequence about something that will be audible.
///
/// A line, not a banner. Filling it and giving it an icon made a technical note the
/// second-loudest thing on the page, which is not what it is worth.
struct SequenceWarning: View {
    let message: String

    var body: some View {
        Text(message)
            .font(DubplateType.metadata)
            .foregroundStyle(DubplateColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
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
