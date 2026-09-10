import Foundation

/// Flattens the library into the value types search ranks over.
///
/// Rebuilt per query rather than maintained as an index: for the library sizes
/// Dubplate is built for this is well under a millisecond, and an index that is
/// never stale is worth more than one that is fast and occasionally wrong.
@MainActor
public enum LibraryIndexing {

    public static func entries(for store: LibraryStore) -> [SearchEntry] {
        var entries: [SearchEntry] = []

        for release in store.releases() {
            entries.append(
                SearchEntry(
                    id: release.id,
                    kind: .release,
                    title: release.title.isEmpty ? "Untitled" : release.title,
                    subtitle: "\(release.artistName) · \(release.subtitleLine)",
                    releaseID: release.id,
                    secondaryText: [release.artistName, release.genre ?? ""]
                )
            )
            entries.append(contentsOf: trackEntries(for: release.orderedTracks, releaseTitle: release.title))
        }
        entries.append(contentsOf: trackEntries(for: store.inboxTracks(), releaseTitle: "Inbox"))
        return entries
    }

    private static func trackEntries(for tracks: [Track], releaseTitle: String) -> [SearchEntry] {
        var entries: [SearchEntry] = []
        for track in tracks {
            let filenames = (track.versions ?? []).compactMap { $0.audioAsset?.originalFilename }
            entries.append(
                SearchEntry(
                    id: track.id,
                    kind: .track,
                    title: track.displayTitle,
                    subtitle: "\(releaseTitle) · \(Formatting.duration(track.duration))",
                    releaseID: track.release?.id,
                    secondaryText: [track.artistName, track.featuredArtists ?? ""] + filenames
                )
            )
            // Versions are searchable by their label and their source filename, so
            // "mix 5" finds the bounce even when nothing else was ever typed in.
            for version in track.versions ?? [] where version.label?.isEmpty == false {
                entries.append(
                    SearchEntry(
                        id: version.id,
                        kind: .version,
                        title: "\(track.displayTitle) — \(version.listeningLabel)",
                        subtitle: "\(releaseTitle) · \(version.shortName)",
                        releaseID: track.release?.id,
                        secondaryText: [version.audioAsset?.originalFilename ?? ""]
                    )
                )
            }
        }
        return entries
    }
}
