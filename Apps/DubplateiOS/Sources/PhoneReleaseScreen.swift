import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// A record on the phone.
///
/// Everything a commercial release page has, and one thing they don't: a track can
/// be swapped to another mix from here. That is secondary and it looks secondary —
/// it lives behind the ellipsis, exactly where a real player puts everything else.
struct PhoneReleaseScreen: View {
    let release: Release

    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var versionsTrack: Track?
    @State private var isDownloading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DubplateLayout.xl) {
                ReleaseHeaderView(
                    release: release,
                    layout: .centred,
                    artworkEdge: 260,
                    onPlay: { services.play(release: release) },
                    onShuffle: { services.play(release: release, shuffled: true) }
                )
                .padding(.top, DubplateLayout.s)

                tracks

                footer
            }
            .padding(.horizontal, DubplateLayout.l)
            .padding(.bottom, 120)
        }
        .background(DubplateColor.ground)
        .navigationTitle(release.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { services.open(release: release) }
        .sheet(item: $versionsTrack) { track in
            VersionPickerSheet(
                track: track,
                playingVersionID: player.currentItem?.versionID,
                onSelect: { version in
                    services.audition(version: version, of: track)
                },
                onSetCurrent: { version in
                    library.makeCurrent(version: version, of: track)
                    services.refreshQueueEntry(for: track)
                },
                onDismiss: { versionsTrack = nil }
            )
            .presentationDetents([.medium, .large])
            .presentationBackground(DubplateColor.playerGround)
        }
    }

    private var tracks: some View {
        LazyVStack(spacing: 0) {
            ForEach(release.orderedTracks) { track in
                HStack(spacing: 0) {
                    Button {
                        services.play(release: release, startingAt: track)
                    } label: {
                        TrackRow(
                            track: track,
                            isCurrent: player.currentItem?.trackID == track.id,
                            isPlaying: player.currentItem?.trackID == track.id && player.isPlaying,
                            onPlay: { services.play(release: release, startingAt: track) }
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if track.versionCount > 1 {
                        Button {
                            versionsTrack = track
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DubplateColor.tertiaryText)
                                .frame(width: DubplateLayout.minimumTapTarget, height: DubplateLayout.minimumTapTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Versions of \(track.displayTitle)")
                    }
                }
                Divider().overlay(DubplateColor.hairline).padding(.leading, 38)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.s) {
            if let copyright = release.copyrightText, !copyright.isEmpty {
                Text(copyright)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
            Text(footerLine)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)

            DownloadButton(release: release)
        }
        .padding(.top, DubplateLayout.l)
    }

    private var footerLine: String {
        var parts: [String] = []
        if let year = release.year { parts.append(String(year)) }
        parts.append(Formatting.longDuration(release.totalDuration))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// "Download Release" / "Remove Download".
///
/// Removing a download only removes it from this phone. The record itself, and
/// every file in it, stays in iCloud — the button says so, because deleting a
/// producer's only copy of a mix by accident is unforgivable.
struct DownloadButton: View {
    let release: Release

    @Environment(AppServices.self) private var services
    @State private var isWorking = false

    var body: some View {
        let state = downloadState
        VStack(alignment: .leading, spacing: DubplateLayout.xs) {
            Button {
                Task { await toggle(state) }
            } label: {
                Label(state.title, systemImage: state.symbol)
            }
            .buttonStyle(DubplateQuietButtonStyle())
            .disabled(isWorking)

            Text(state.detail(size: totalSize))
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
        }
    }

    private enum State {
        case downloaded
        case notDownloaded
        case partial

        var title: String {
            switch self {
            case .downloaded: return "Remove Download"
            case .notDownloaded: return "Download Release"
            case .partial: return "Finish Downloading"
            }
        }

        var symbol: String {
            switch self {
            case .downloaded: return "checkmark.circle"
            case .notDownloaded, .partial: return "arrow.down.circle"
            }
        }

        func detail(size: Int64) -> String {
            switch self {
            case .downloaded: return "\(Formatting.fileSize(size)) on this iPhone. Your iCloud copy stays put."
            case .notDownloaded: return "\(Formatting.fileSize(size)) — keeps playing with no signal."
            case .partial: return "Some tracks are still in iCloud."
            }
        }
    }

    private var assets: [AudioAsset] {
        release.orderedTracks.compactMap(\.currentAsset)
    }

    private var totalSize: Int64 {
        assets.reduce(0) { $0 + $1.fileSize }
    }

    private var downloadState: State {
        let states = assets.map(\.availability)
        guard !states.isEmpty else { return .notDownloaded }
        if states.allSatisfy({ $0.isPlayableNow }) { return .downloaded }
        if states.contains(where: { $0.isPlayableNow }) { return .partial }
        return .notDownloaded
    }

    private func toggle(_ state: State) async {
        isWorking = true
        defer { isWorking = false }
        switch state {
        case .downloaded:
            await services.removeDownload(for: release)
        case .notDownloaded, .partial:
            await services.download(release: release)
        }
    }
}
