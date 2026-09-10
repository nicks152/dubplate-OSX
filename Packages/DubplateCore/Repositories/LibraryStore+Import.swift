import Foundation
import SwiftData

/// What a drop actually did, so the interface can say so and offer an undo.
public struct ImportOutcome: Sendable {
    public var createdTracks: [UUID] = []
    public var addedVersions: [UUID] = []
    public var duplicateFilenames: [String] = []
    public var failures: [DubplateError] = []

    public var isEmpty: Bool {
        createdTracks.isEmpty && addedVersions.isEmpty
    }

    /// "8 tracks added" / "New version of Midnight" — one line, past tense.
    public func summary(trackTitle: String?) -> String {
        var parts: [String] = []
        if !createdTracks.isEmpty {
            parts.append("\(createdTracks.count) track\(createdTracks.count == 1 ? "" : "s") added")
        }
        if !addedVersions.isEmpty {
            if addedVersions.count == 1, let trackTitle {
                parts.append("New version of \(trackTitle)")
            } else {
                parts.append("\(addedVersions.count) new versions")
            }
        }
        if !duplicateFilenames.isEmpty {
            parts.append("\(duplicateFilenames.count) already imported")
        }
        return parts.joined(separator: " · ")
    }
}

/// What to do when a bounce is dropped straight onto an existing track.
public enum TrackDropChoice: String, CaseIterable, Identifiable, Sendable {
    case addAsNewVersion
    case replaceCurrentVersion
    case createNewTrack

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .addAsNewVersion: return "Add as New Version"
        case .replaceCurrentVersion: return "Replace Current Version"
        case .createNewTrack: return "Create New Track"
        }
    }

    public var explanation: String {
        switch self {
        case .addAsNewVersion: return "Keeps the old mix and starts playing the new one."
        case .replaceCurrentVersion: return "Swaps the audio and deletes the old file."
        case .createNewTrack: return "Adds it to the record as a separate song."
        }
    }

    /// The default. Adding is never destructive, so it is always the safe answer.
    public static let recommended = TrackDropChoice.addAsNewVersion
}

extension LibraryStore {

    /// Builds a plan for a set of dropped URLs against a release.
    public func plan(for urls: [URL], in release: Release?) -> ImportPlan {
        let candidates = urls.enumerated().map { ImportCandidate.make(url: $1, dropIndex: $0) }
        let existing = release.map { summaries(for: $0) } ?? []
        return ImportPlanner.plan(
            candidates: candidates,
            existingTracks: existing,
            nextTrackNumber: (release?.trackCount ?? 0) + 1
        )
    }

    public func summaries(for release: Release) -> [TrackSummary] {
        release.orderedTracks.map { track in
            var keys = [FilenameParser.normalize(track.title)]
            for version in track.versions ?? [] {
                if let filename = version.audioAsset?.originalFilename {
                    keys.append(FilenameParser.parse(filename).matchKey)
                }
            }
            return TrackSummary(
                id: track.id,
                title: track.displayTitle,
                trackNumber: track.trackNumber,
                matchKeys: Array(Set(keys.filter { !$0.isEmpty }))
            )
        }
    }

    /// Carries out a plan. Files are copied and read off the main actor; only the
    /// model writes happen here.
    @discardableResult
    public func apply(_ plan: ImportPlan, to release: Release?) async -> ImportOutcome {
        var outcome = ImportOutcome()
        let total = plan.audioFileCount + plan.artwork.count + plan.motion.count
        guard total > 0 else { return outcome }

        var completed = 0
        setImportProgress(ImportProgress(completed: 0, total: total))

        for planned in plan.newTracks {
            var createdTrack: Track?
            for candidate in planned.candidates {
                setImportProgress(
                    ImportProgress(completed: completed, total: total, currentFilename: candidate.filename)
                )
                guard let ingested = await ingest(candidate, into: &outcome) else {
                    completed += 1
                    continue
                }
                if let track = createdTrack {
                    let version = addVersion(from: ingested, to: track, makeCurrent: true)
                    outcome.addedVersions.append(version.id)
                } else {
                    let track = makeTrack(
                        named: planned.title,
                        number: planned.trackNumber,
                        release: release,
                        ingested: ingested
                    )
                    createdTrack = track
                    outcome.createdTracks.append(track.id)
                }
                completed += 1
            }
        }

        for planned in plan.newVersions {
            setImportProgress(
                ImportProgress(completed: completed, total: total, currentFilename: planned.candidate.filename)
            )
            completed += 1
            guard let track = track(id: planned.match.trackID) else { continue }
            guard let ingested = await ingest(planned.candidate, into: &outcome) else { continue }
            let version = addVersion(from: ingested, to: track, makeCurrent: true)
            outcome.addedVersions.append(version.id)
        }

        if let release {
            for candidate in plan.artwork {
                setImportProgress(
                    ImportProgress(completed: completed, total: total, currentFilename: candidate.filename)
                )
                completed += 1
                await setArtwork(from: candidate.url, for: release)
            }
            for candidate in plan.motion {
                setImportProgress(
                    ImportProgress(completed: completed, total: total, currentFilename: candidate.filename)
                )
                completed += 1
                await setAnimatedArtwork(from: candidate.url, for: release)
            }
            release.normalizeOrder()
        }

        setImportProgress(nil)
        save()
        return outcome
    }

    /// Drops one bounce onto one track.
    @discardableResult
    public func apply(
        choice: TrackDropChoice,
        url: URL,
        to track: Track
    ) async -> ImportOutcome {
        var outcome = ImportOutcome()
        let candidate = ImportCandidate.make(url: url, dropIndex: 0)
        setImportProgress(ImportProgress(completed: 0, total: 1, currentFilename: candidate.filename))
        defer { setImportProgress(nil) }

        switch choice {
        case .createNewTrack:
            guard let ingested = await ingest(candidate, into: &outcome) else { return outcome }
            let release = track.release
            let created = makeTrack(
                named: candidate.parsed.title,
                number: (release?.trackCount ?? 0) + 1,
                release: release,
                ingested: ingested
            )
            release?.normalizeOrder()
            outcome.createdTracks.append(created.id)

        case .addAsNewVersion:
            guard let ingested = await ingest(candidate, into: &outcome) else { return outcome }
            let version = addVersion(from: ingested, to: track, makeCurrent: true)
            outcome.addedVersions.append(version.id)

        case .replaceCurrentVersion:
            guard let ingested = await ingest(candidate, into: &outcome) else { return outcome }
            let previous = track.currentVersion
            let version = addVersion(from: ingested, to: track, makeCurrent: true)
            outcome.addedVersions.append(version.id)
            if let previous {
                delete(version: previous)
            }
        }
        save()
        return outcome
    }

    // MARK: - Artwork

    public func setArtwork(from url: URL, for release: Release) async {
        do {
            let ingested = try await ingestor.ingestArtwork(from: url)
            let destination = mediaStore.url(forRelativePath: ingested.relativePath)
            let size = ImageInspector.pixelSize(ofFileAt: destination)
            let asset = ArtworkAsset(
                id: ingested.assetID,
                kind: .staticArtwork,
                filename: destination.lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                width: size.width,
                height: size.height,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            asset.thumbnailData = ImageInspector.thumbnailData(ofFileAt: destination)
            context.insert(asset)
            if let previous = release.artwork {
                await ingestor.removeMedia(atRelativePath: previous.relativePath)
                context.delete(previous)
            }
            release.artwork = asset
            release.updatedAt = Date()
            save()
        } catch let error as DubplateError {
            lastError = error
        } catch {
            lastError = DubplateError(.artworkUnreadable, subject: url.lastPathComponent, underlying: error)
        }
    }

    public func setAnimatedArtwork(from url: URL, for release: Release) async {
        do {
            let ingested = try await ingestor.ingestArtwork(from: url)
            let asset = ArtworkAsset(
                id: ingested.assetID,
                kind: .animatedArtwork,
                filename: mediaStore.url(forRelativePath: ingested.relativePath).lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            context.insert(asset)
            if let previous = release.animatedArtwork {
                await ingestor.removeMedia(atRelativePath: previous.relativePath)
                context.delete(previous)
            }
            release.animatedArtwork = asset
            release.updatedAt = Date()
            save()
        } catch let error as DubplateError {
            lastError = error
        } catch {
            lastError = DubplateError(.importFailed, subject: url.lastPathComponent, underlying: error)
        }
    }

    public func setCanvas(from url: URL, for track: Track) async {
        do {
            let ingested = try await ingestor.ingestArtwork(from: url)
            let asset = ArtworkAsset(
                id: ingested.assetID,
                kind: .trackVideo,
                filename: mediaStore.url(forRelativePath: ingested.relativePath).lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            context.insert(asset)
            if let previous = track.canvas {
                await ingestor.removeMedia(atRelativePath: previous.relativePath)
                context.delete(previous)
            }
            track.canvas = asset
            track.updatedAt = Date()
            save()
        } catch let error as DubplateError {
            lastError = error
        } catch {
            lastError = DubplateError(.importFailed, subject: url.lastPathComponent, underlying: error)
        }
    }

    // MARK: - Building blocks

    private func ingest(_ candidate: ImportCandidate, into outcome: inout ImportOutcome) async -> IngestedFile? {
        do {
            let ingested = try await ingestor.ingestAudio(from: candidate.url)
            if let existing = existingAsset(withChecksum: ingested.checksum), !ingested.checksum.isEmpty {
                // The identical file is already in the library. Keep the original
                // and throw away the copy rather than storing the bytes twice.
                await ingestor.removeMedia(atRelativePath: ingested.relativePath)
                outcome.duplicateFilenames.append(candidate.filename)
                Log.media.info("Skipped duplicate import of \(candidate.filename, privacy: .public)")
                _ = existing
                return nil
            }
            return ingested
        } catch let error as DubplateError {
            outcome.failures.append(error)
            lastError = error
            return nil
        } catch {
            let wrapped = DubplateError(.importFailed, subject: candidate.filename, underlying: error)
            outcome.failures.append(wrapped)
            lastError = wrapped
            return nil
        }
    }

    private func existingAsset(withChecksum checksum: String) -> AudioAsset? {
        guard !checksum.isEmpty else { return nil }
        let descriptor = FetchDescriptor<AudioAsset>(predicate: #Predicate { $0.checksum == checksum })
        return try? context.fetch(descriptor).first
    }

    private func makeTrack(
        named title: String,
        number: Int,
        release: Release?,
        ingested: IngestedFile
    ) -> Track {
        let track = Track(
            title: title,
            artistName: release?.artistName ?? defaultArtistName,
            trackNumber: number
        )
        context.insert(track)
        track.release = release
        if let release {
            release.trackOrder.append(track.id.uuidString)
            release.updatedAt = Date()
        }
        let version = addVersion(from: ingested, to: track, makeCurrent: true)
        track.duration = version.audioAsset?.duration ?? 0
        return track
    }

    @discardableResult
    private func addVersion(from ingested: IngestedFile, to track: Track, makeCurrent: Bool) -> TrackVersion {
        let asset = AudioAsset(
            id: ingested.assetID,
            filename: mediaStore.url(forRelativePath: ingested.relativePath).lastPathComponent,
            originalFilename: ingested.originalFilename,
            relativePath: ingested.relativePath,
            duration: ingested.info.duration,
            format: ingested.info.format,
            fileSize: ingested.fileSize,
            checksum: ingested.checksum
        )
        context.insert(asset)

        let parsed = FilenameParser.parse(ingested.originalFilename)
        let version = TrackVersion(
            versionNumber: track.nextVersionNumber,
            label: parsed.versionLabel,
            audioAsset: asset
        )
        context.insert(version)
        version.track = track
        if track.versions == nil { track.versions = [] }
        if makeCurrent {
            track.makeCurrent(version)
        }
        track.updatedAt = Date()
        track.release?.updatedAt = track.updatedAt
        return version
    }
}
