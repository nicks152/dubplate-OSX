import SwiftUI
import DubplateCore

/// A release's track list.
///
/// Reorder is a drag, not a mode: there is no edit button to find, because
/// sequencing a record is the single thing people do most in Dubplate. Dropping a
/// bounce onto a row is how a mix gets replaced, which is the second.
public struct TrackListView: View {
    private let tracks: [Track]
    private let currentTrackID: UUID?
    private let isPlaying: Bool
    private let playingVersionID: UUID?
    private let allowsReordering: Bool
    @Binding private var selection: UUID?
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onPlay: (Track) -> Void
    private let onMove: ((IndexSet, Int) -> Void)?
    private let onDropAudio: ((Track, [URL]) -> Void)?
    private let onShowVersions: ((Track) -> Void)?
    private let onRemove: ((Track) -> Void)?
    private let onDelete: ((Track) -> Void)?

    public init(
        tracks: [Track],
        currentTrackID: UUID?,
        isPlaying: Bool,
        playingVersionID: UUID? = nil,
        selection: Binding<UUID?>,
        allowsReordering: Bool = true,
        onPlay: @escaping (Track) -> Void,
        onMove: ((IndexSet, Int) -> Void)? = nil,
        onDropAudio: ((Track, [URL]) -> Void)? = nil,
        onShowVersions: ((Track) -> Void)? = nil,
        onRemove: ((Track) -> Void)? = nil,
        onDelete: ((Track) -> Void)? = nil
    ) {
        self.tracks = tracks
        self.currentTrackID = currentTrackID
        self.isPlaying = isPlaying
        self.playingVersionID = playingVersionID
        self._selection = selection
        self.allowsReordering = allowsReordering
        self.onPlay = onPlay
        self.onMove = onMove
        self.onDropAudio = onDropAudio
        self.onShowVersions = onShowVersions
        self.onRemove = onRemove
        self.onDelete = onDelete
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(tracks) { track in
                TrackRow(
                    track: track,
                    isCurrent: track.id == currentTrackID,
                    isPlaying: track.id == currentTrackID && isPlaying,
                    playingVersionID: track.id == currentTrackID ? playingVersionID : nil,
                    onPlay: { onPlay(track) },
                    onShowVersions: onShowVersions.map { handler in { handler(track) } }
                )
                .tag(track.id)
                .listRowInsets(EdgeInsets(top: 2, leading: DubplateLayout.s, bottom: 2, trailing: DubplateLayout.s))
                .listRowBackground(rowBackground(for: track))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onPlay(track) }
                .onTapGesture { selection = track.id }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let onDropAudio else { return false }
                    // Folders and every file in the drop, not just the first one.
                    let audio = DroppedFiles.expand(urls)
                        .filter { FilenameParser.isAudio($0.lastPathComponent) }
                    guard !audio.isEmpty else { return false }
                    onDropAudio(track, audio)
                    return true
                }
                .contextMenu {
                    Button("Play") { onPlay(track) }
                    if let onShowVersions, track.versionCount > 1 {
                        Button("Mixes…") { onShowVersions(track) }
                    }
                    Divider()
                    if let onRemove {
                        // Non-destructive: nothing is deleted, the track just stops
                        // being part of this record.
                        Button(track.release == nil ? "Add to Release…" : "Move to Inbox") {
                            onRemove(track)
                        }
                    }
                    if let onDelete {
                        Button(deleteTitle(for: track), role: .destructive) { onDelete(track) }
                    }
                }
            }
            .onMove { offsets, destination in
                guard allowsReordering else { return }
                onMove?(offsets, destination)
            }
            .moveDisabled(!allowsReordering)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(DubplateMotion.standard, value: tracks.map(\.id))
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            // A record arriving all at once is a table refreshing. Arriving is worth
            // a beat — one, not a cascade.
            withAnimation(DubplateMotion.respecting(reduceMotion, DubplateMotion.standard)) {
                hasAppeared = true
            }
        }
    }

    /// Names what will actually be destroyed, because "Remove from Release" did not.
    private func deleteTitle(for track: Track) -> String {
        track.versionCount > 1
            ? "Delete Track and Its \(track.versionCount) Mixes…"
            : "Delete Track…"
    }

    private func rowBackground(for track: Track) -> some View {
        RoundedRectangle(cornerRadius: DubplateLayout.controlRadius - 2, style: .continuous)
            .fill(selection == track.id ? DubplateColor.sunken : .clear)
    }
}
