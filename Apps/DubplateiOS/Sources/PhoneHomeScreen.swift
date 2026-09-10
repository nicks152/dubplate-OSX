import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// Home: what you played last, then everything.
struct PhoneHomeScreen: View {
    @Binding var path: NavigationPath
    @Binding var searchText: String
    @Binding var isImporting: Bool

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Query(sort: \Release.updatedAt, order: .reverse) private var releases: [Release]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DubplateLayout.xxl) {
                if !searchText.isEmpty {
                    searchResults
                } else {
                    if let recent = mostRecent {
                        featured(recent)
                    }
                    if !otherRecents.isEmpty {
                        VStack(alignment: .leading, spacing: DubplateLayout.m) {
                            SectionHeader("Recently Played")
                            ReleaseShelf(releases: otherRecents) { open($0) }
                        }
                    }
                    yourMusic
                }
            }
            .padding(.horizontal, DubplateLayout.l)
            .padding(.bottom, 120)
        }
        .background(DubplateColor.ground)
        .navigationTitle("Dubplate")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Releases, tracks, filenames")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add Audio…", systemImage: "plus") { isImporting = true }
                    NavigationLink("Settings") { PhoneSettingsScreen() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .refreshable { await services.sync.syncNow() }
        .overlay {
            if releases.isEmpty && searchText.isEmpty {
                EmptyState(
                    headline: "Nothing here yet",
                    message: "Build a release on your Mac and it’ll appear here — artwork, sequence and all."
                )
            }
        }
    }

    private var mostRecent: Release? {
        releases.first { $0.lastPlayedAt != nil } ?? releases.first
    }

    private var otherRecents: [Release] {
        releases
            .filter { $0.lastPlayedAt != nil && $0.id != mostRecent?.id }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    private func featured(_ release: Release) -> some View {
        Button {
            open(release)
        } label: {
            VStack(alignment: .leading, spacing: DubplateLayout.l) {
                ArtworkView(
                    asset: release.artwork,
                    title: release.title,
                    cornerRadius: DubplateLayout.largeArtworkRadius
                )
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.title.isEmpty ? "Untitled" : release.title)
                            .dubplateDisplayStyle(size: 26)
                            .foregroundStyle(DubplateColor.primaryText)
                        Text(release.artistName)
                            .font(.system(size: 15))
                            .foregroundStyle(DubplateColor.secondaryText)
                        Text(release.subtitleLine)
                            .font(DubplateType.metadata)
                            .foregroundStyle(DubplateColor.tertiaryText)
                    }
                    Spacer()
                    Button {
                        services.play(release: release)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DubplateColor.ground)
                            .frame(width: 52, height: 52)
                            .background(DubplateColor.primaryText, in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Play \(release.title)")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var yourMusic: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.m) {
            SectionHeader("Your Music")
            LibraryGrid(
                releases: releases,
                playingReleaseID: player.currentItem?.releaseID,
                onOpen: { open($0) },
                onPlay: { services.play(release: $0) }
            )
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.m) {
            let results = LibrarySearch.run(query: searchText, over: LibraryIndexing.entries(for: library))
            if results.isEmpty {
                EmptyState(headline: "Nothing matches", message: "Try a track name, an artist, or part of a filename.")
            } else {
                ForEach(results) { result in
                    Button {
                        if let releaseID = result.releaseID { openID(releaseID) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(DubplateType.rowTitle)
                                .foregroundStyle(DubplateColor.primaryText)
                            Text(result.subtitle)
                                .font(DubplateType.metadata)
                                .foregroundStyle(DubplateColor.tertiaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: DubplateLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DubplateColor.hairline)
                }
            }
        }
    }

    private func open(_ release: Release) {
        openID(release.id)
    }

    private func openID(_ id: UUID) {
        path.append(id)
    }
}
