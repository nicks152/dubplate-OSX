import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// The sidebar.
///
/// Five places and a list of records. Nothing is nested, nothing is disclosed, and
/// there are no counts next to anything — a producer knows how many albums they
/// have.
struct MacSidebar: View {
    @Binding var section: LibrarySection
    @Binding var isShowingNewRelease: Bool

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Query(sort: \Release.updatedAt, order: .reverse) private var releases: [Release]
    @State private var releaseToDelete: Release?

    var body: some View {
        List(selection: selectionBinding) {
            // Text rows: a square for EPs and a circle for Singles meant nothing,
            // and six icons beside six words is chrome outnumbering content.
            Section("Library") {
                row(.recentlyPlayed)
                row(.albums)
                row(.eps)
                row(.singles)
                row(.projects)
                row(.inbox)
            }

            if !releases.isEmpty {
                Section("Releases") {
                    ForEach(releases) { release in
                        releaseRow(release)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                isShowingNewRelease = true
            } label: {
                Label("New Release", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DubplateLayout.m)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DubplateColor.secondaryText)
            .padding(DubplateLayout.s)
            .keyboardShortcut("n", modifiers: .command)
        }
        // Deleting a record destroys every mix in it. It is not a menu item you
        // walk past on the way to something else.
        .confirmationDialog(
            deletePrompt,
            isPresented: Binding(get: { releaseToDelete != nil }, set: { if !$0 { releaseToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Release", role: .destructive) {
                guard let release = releaseToDelete else { return }
                if case .release(let id) = section, id == release.id {
                    section = .albums
                }
                services.delete(release: release)
                releaseToDelete = nil
            }
            Button("Cancel", role: .cancel) { releaseToDelete = nil }
        } message: {
            Text("Deleted from this Mac and from iCloud. This can’t be undone.")
        }
    }

    private var deletePrompt: String {
        guard let release = releaseToDelete else { return "" }
        let mixes = release.orderedTracks.reduce(0) { $0 + $1.versionCount }
        return "Delete “\(release.title.isEmpty ? "Untitled" : release.title)” — \(release.trackCount) tracks, \(mixes) mixes?"
    }

    private var selectionBinding: Binding<LibrarySection?> {
        Binding(
            get: { section },
            set: { if let value = $0 { section = value } }
        )
    }

    private func row(_ target: LibrarySection) -> some View {
        Text(target.title)
            .font(.system(size: 13))
            .frame(height: 22)
            .tag(target)
    }

    private func releaseRow(_ release: Release) -> some View {
        HStack(spacing: DubplateLayout.s) {
            ArtworkView(asset: release.artwork, title: release.title, cornerRadius: 3)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(release.title.isEmpty ? "Untitled" : release.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if player.currentItem?.releaseID == release.id {
                PlayingIndicator(isAnimating: player.isPlaying)
            }
        }
        .tag(LibrarySection.release(release.id))
        .contextMenu {
            Button("Play") { services.play(release: release) }
            Button("Open") { section = .release(release.id) }
            Divider()
            Button("Delete Release…", role: .destructive) { releaseToDelete = release }
        }
    }
}

/// The one place sync is ever mentioned unprompted, and only when it has something
/// to say.
struct SyncStatusLabel: View {
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        if sync.status.isWorthMentioning {
            HStack(spacing: DubplateLayout.xs) {
                if sync.status == .syncing || sync.status == .downloading {
                    ProgressView().controlSize(.mini)
                }
                Text(label)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
                    .lineLimit(1)
            }
            .help(detail)
            .accessibilityLabel("Sync status: \(label)")
        }
    }

    /// Names the file rather than saying "Syncing" for the length of an album.
    private var label: String {
        guard let transfer = sync.transfers.first else { return sync.status.label }
        let more = sync.transfers.count - 1
        let verb = transfer.isUpload ? "Uploading" : "Downloading"
        return more > 0 ? "\(verb) \(transfer.filename) · \(more) to go" : "\(verb) \(transfer.filename)"
    }

    private var detail: String {
        sync.transfers.isEmpty
            ? sync.status.label
            : sync.transfers.map(\.filename).joined(separator: "\n")
    }
}
