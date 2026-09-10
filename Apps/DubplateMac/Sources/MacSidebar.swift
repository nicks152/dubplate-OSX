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

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Query(sort: \Release.updatedAt, order: .reverse) private var releases: [Release]

    var body: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                row(.recentlyPlayed, systemImage: "clock")
                row(.albums, systemImage: "square.stack")
                row(.eps, systemImage: "square")
                row(.singles, systemImage: "circle")
                row(.projects, systemImage: "tray.full")
                row(.inbox, systemImage: "tray")
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
    }

    private var selectionBinding: Binding<LibrarySection?> {
        Binding(
            get: { section },
            set: { if let value = $0 { section = value } }
        )
    }

    private func row(_ target: LibrarySection, systemImage: String) -> some View {
        Label(target.title, systemImage: systemImage)
            .font(.system(size: 13))
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
            Button("Play") {
                section = .release(release.id)
            }
            Divider()
            Button("Delete Release", role: .destructive) {
                if case .release(let id) = section, id == release.id {
                    section = .albums
                }
                library.delete(release: release)
            }
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
                if sync.status == .syncing {
                    ProgressView().controlSize(.mini)
                }
                Text(sync.status.label)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
            .accessibilityLabel("Sync status: \(sync.status.label)")
        }
    }
}
