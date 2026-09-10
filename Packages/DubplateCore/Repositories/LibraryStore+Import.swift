import Foundation
import SwiftData

/// What a drop actually did, so the interface can say so and offer an undo.
public struct ImportOutcome: Sendable {
    public var createdTracks: [UUID] = []
    public var addedVersions: [UUID] = []
    public var duplicateFilenames: [String] = []
    /// Files whose bytes had gone missing and were put back by this import.
    public var repairedFilenames: [String] = []
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
        if !repairedFilenames.isEmpty {
            parts.append("\(repairedFilenames.count) file\(repairedFilenames.count == 1 ? "" : "s") restored")
        }
        if !duplicateFilenames.isEmpty {
            parts.append("\(duplicateFilenames.count) already on this release")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) couldn’t be read")
        }
        return parts.isEmpty ? "Nothing to add" : parts.joined(separator: " · ")
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
    ///
    /// Folders are walked first: a bounce folder is the most obvious thing to drag
    /// in, and a handler that only understands loose files refuses it silently.
    ///
    /// Off the main actor, all of it. Walking the folders touches the file system
    /// once per entry, and matching every dropped bounce against every track
    /// already on the record is quadratic — on a dropped archive of a few hundred
    /// files that was a visibly frozen window before a single note had been heard.
    /// Only the summaries, which read the model, are gathered here.
    public func plan(for urls: [URL], in release: Release?) async -> ImportPlan {
        let existing = release.map { summaries(for: $0) } ?? []
        let nextNumber = (release?.trackCount ?? 0) + 1
        return await Task.detached(priority: .userInitiated) {
            let expansion = DroppedFiles.expanded(urls)
            let candidates = expansion.files.enumerated().map {
                ImportCandidate.make(url: $1, dropIndex: $0)
            }
            var plan = ImportPlanner.plan(
                candidates: candidates,
                existingTracks: existing,
                nextTrackNumber: nextNumber
            )
            plan.wasTruncated = expansion.wasTruncated
            return plan
        }.value
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
                // A merge from another device can delete the release mid-import;
                // touching an invalidated model is a trap, not an error.
                if let release, release.isDeleted { break }
                setImportProgress(
                    ImportProgress(completed: completed, total: total, currentFilename: candidate.filename)
                )
                guard let ingested = await ingest(candidate, target: createdTrack, into: &outcome) else {
                    completed += 1
                    continue
                }
                if let track = createdTrack {
                    let version = addVersion(from: ingested, to: track)
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
            // Re-fetched rather than captured, for the same reason.
            guard let track = track(id: planned.match.trackID), !track.isDeleted else { continue }
            guard let ingested = await ingest(planned.candidate, target: track, into: &outcome) else { continue }
            let version = addVersion(from: ingested, to: track)
            outcome.addedVersions.append(version.id)
        }

        if let release, !release.isDeleted {
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
        guard !track.isDeleted else { return outcome }

        switch choice {
        case .createNewTrack:
            guard let ingested = await ingest(candidate, target: nil, into: &outcome) else { return outcome }
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
            guard let ingested = await ingest(candidate, target: track, into: &outcome) else { return outcome }
            let version = addVersion(from: ingested, to: track)
            outcome.addedVersions.append(version.id)

        case .replaceCurrentVersion:
            guard let ingested = await ingest(candidate, target: track, into: &outcome) else { return outcome }
            let previous = track.currentVersion
            let version = addVersion(from: ingested, to: track, makeCurrent: true, force: true)
            outcome.addedVersions.append(version.id)
            if let previous {
                delete(version: previous)
            }
        }
        save()
        return outcome
    }

    // MARK: - Building blocks

    /// What an existing copy of these bytes means for this particular drop.
    private enum ExistingBytes {
        /// Nothing like it in the library.
        case none
        /// Already a version of the track being dropped on — genuinely a duplicate.
        case duplicateOfTarget
        /// Somewhere else in the library, and the file is present. The same master
        /// can appear on a single and on the album; reuse it rather than storing
        /// the bytes twice.
        case reusable(AudioAsset)
        /// The library knows this file but the bytes have gone. Put them back.
        case repairable(AudioAsset)
    }

    private func ingest(
        _ candidate: ImportCandidate,
        target: Track?,
        into outcome: inout ImportOutcome
    ) async -> IngestedFile? {
        do {
            let ingested = try await ingestor.ingestAudio(from: candidate.url)
            let incomingFile = mediaStore.url(forRelativePath: ingested.relativePath)
            switch existingBytes(checksum: ingested.checksum, incomingFile: incomingFile, target: target) {
            case .none:
                return ingested

            case .duplicateOfTarget:
                await ingestor.removeMedia(atRelativePath: ingested.relativePath)
                outcome.duplicateFilenames.append(candidate.filename)
                Log.media.info("Already on this release: \(candidate.filename, privacy: .public)")
                return nil

            case .repairable(let asset):
                // The error copy promises "drop the bounce in again to restore it",
                // so it has to actually restore it.
                do {
                    try mediaStore.adopt(
                        temporaryFile: incomingFile,
                        asRelativePath: asset.relativePath
                    )
                    asset.localPresence = true
                    asset.transferState = nil
                    outcome.repairedFilenames.append(candidate.filename)
                    Log.media.info("Restored missing media for \(candidate.filename, privacy: .public)")
                } catch {
                    Log.media.error("Could not restore media: \(String(describing: error))")
                }
                return nil

            case .reusable(let asset):
                await ingestor.removeMedia(atRelativePath: ingested.relativePath)
                var reused = ingested
                reused.assetID = asset.id
                reused.relativePath = asset.relativePath
                return reused
            }
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

    /// Decides what an existing copy of these bytes means for this drop.
    ///
    /// A signature match is only a candidate. Two mixes of the same song have the
    /// same length and near-identical heads and tails, so concluding identity from
    /// the signature discarded the producer's new mix and told them Dubplate already
    /// had it. Every branch that acts on identity is confirmed byte-for-byte first.
    private func existingBytes(
        checksum: String,
        incomingFile: URL,
        target: Track?
    ) -> ExistingBytes {
        guard !checksum.isEmpty else { return .none }
        let descriptor = FetchDescriptor<AudioAsset>(predicate: #Predicate { $0.checksum == checksum })
        guard let existing = try? context.fetch(descriptor).first else { return .none }

        let existingFile = mediaStore.url(forRelativePath: existing.relativePath)
        guard mediaStore.exists(relativePath: existing.relativePath) else {
            // The library knows this signature but the bytes are gone. There is
            // nothing to compare against, so this can only be a repair if the
            // *description* matches too.
            guard existing.fileSize == ((try? Checksum.fileSize(of: incomingFile)) ?? -1),
                  existing.originalFilename == incomingFile.lastPathComponent
            else {
                return .none
            }
            return .repairable(existing)
        }

        guard Checksum.areIdentical(existingFile, incomingFile) else {
            // Same signature, different audio: a new mix, and an ordinary import.
            Log.media.info("Signature collision between two different files; importing both")
            return .none
        }

        let alreadyOnTarget = (target?.versions ?? []).contains { $0.audioAsset?.id == existing.id }
        return alreadyOnTarget ? .duplicateOfTarget : .reusable(existing)
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
            featuredArtists: FilenameParser.parse(ingested.originalFilename).featuredArtists,
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

    /// Adds a bounce as a version.
    ///
    /// It becomes the current mix unless its name says it is a different rendering
    /// rather than a newer one: dropping a folder of instrumentals onto an album
    /// must not silently replace every vocal.
    @discardableResult
    private func addVersion(
        from ingested: IngestedFile,
        to track: Track,
        makeCurrent: Bool = true,
        force: Bool = false
    ) -> TrackVersion {
        let asset: AudioAsset
        if let reused = assetIfPresent(id: ingested.assetID) {
            // The same master appearing on a second record: one file, two versions.
            asset = reused
        } else {
            asset = AudioAsset(
                id: ingested.assetID,
                filename: mediaStore.url(forRelativePath: ingested.relativePath).lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                duration: ingested.info.duration,
                format: ingested.info.format,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            asset.sourceFolder = ingested.sourceFolder
            context.insert(asset)
        }

        let parsed = FilenameParser.parse(ingested.originalFilename)
        let version = TrackVersion(
            versionNumber: track.nextVersionNumber,
            label: parsed.versionLabel,
            audioAsset: asset
        )
        context.insert(version)
        version.track = track
        if track.versions == nil { track.versions = [] }
        if makeCurrent, force || !parsed.isVariant || track.currentVersion == nil {
            track.makeCurrent(version)
        }
        track.updatedAt = Date()
        track.release?.updatedAt = track.updatedAt
        return version
    }

    private func assetIfPresent(id: UUID) -> AudioAsset? {
        let descriptor = FetchDescriptor<AudioAsset>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
