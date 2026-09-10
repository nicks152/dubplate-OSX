import Foundation
import SwiftData
import DubplateCore
import DubplateAudio

/// Works out the things that are nice to know but must never hold anything up.
///
/// Waveforms and loudness are computed after an import has already finished and the
/// music is already playable, one file at a time at utility priority. Nothing in the
/// application waits for this, and a failure here is never shown to anyone.
@MainActor
public final class MediaAnalyser {
    private let context: ModelContext
    private let mediaStore: MediaStore
    private let settings: DubplateSettings
    private var work: Task<Void, Never>?

    public init(context: ModelContext, mediaStore: MediaStore, settings: DubplateSettings) {
        self.context = context
        self.mediaStore = mediaStore
        self.settings = settings
    }

    /// Analyses anything in the library that has not been analysed yet.
    public func analysePending(limit: Int = 40) {
        guard work == nil else { return }
        work = Task { [weak self] in
            await self?.run(limit: limit)
            self?.work = nil
        }
    }

    public func cancel() {
        work?.cancel()
        work = nil
    }

    /// Assets that cannot be analysed this session — not downloaded, or unreadable.
    ///
    /// Without this the pass re-fetched the same rows forever: the predicate is
    /// "has no waveform", and a file that is not on this device can never get one.
    /// On a phone holding a synced catalogue and no audio that was a fully
    /// synchronous main-actor loop with no suspension point, which is a watchdog
    /// kill within seconds of launch.
    private var skipped: Set<UUID> = []

    private func run(limit: Int) async {
        // One `#Predicate` per statement, each with the type written out. A
        // ternary between two of them expands to two large macro bodies inside one
        // expression, and the type-checker gives up rather than solving it — which
        // then cascades into every line that touches the descriptor.
        let predicate: Predicate<AudioAsset>
        if settings.measuresLoudness {
            predicate = #Predicate { $0.waveformPeaks == nil || $0.integratedLoudness == nil }
        } else {
            predicate = #Predicate { $0.waveformPeaks == nil }
        }
        var descriptor = FetchDescriptor<AudioAsset>(predicate: predicate)
        // Without a limit this hydrates every unanalysed asset in the library on the
        // main actor to take the first forty.
        descriptor.fetchLimit = limit + skipped.count
        let assets = ((try? context.fetch(descriptor)) ?? [])
            .filter { !skipped.contains($0.id) }
            .prefix(limit)
        guard !assets.isEmpty else { return }

        var analysed = 0
        for asset in assets {
            if Task.isCancelled { return }
            // Yield on every asset, including the ones that are skipped.
            await Task.yield()
            guard !asset.isDeleted else { continue }
            guard mediaStore.exists(relativePath: asset.relativePath) else {
                skipped.insert(asset.id)
                continue
            }

            let url = mediaStore.url(forRelativePath: asset.relativePath)
            if asset.waveformPeaks == nil {
                if let peaks = try? await WaveformGenerator().peaks(forFileAt: url), !peaks.isEmpty {
                    guard !asset.isDeleted else { continue }
                    asset.waveformPeaks = peaks
                    analysed += 1
                } else {
                    // A file the system cannot read will never produce peaks; one of
                    // them must not keep the pass alive forever.
                    skipped.insert(asset.id)
                    continue
                }
            }
            if wantsLoudness, asset.integratedLoudness == nil {
                if let loudness = try? await LoudnessAnalyzer().integratedLoudness(ofFileAt: url),
                   loudness.isFinite {
                    // The model may have been deleted by a merge while this ran.
                    guard !asset.isDeleted else { continue }
                    asset.integratedLoudness = loudness
                }
            }
            try? context.save()
        }
        // Keep going while progress is being made, and stop the moment it is not.
        if analysed > 0, !Task.isCancelled {
            await run(limit: limit)
        }
    }

    /// Called when a download lands, so files that were skipped get another go.
    public func reconsiderSkipped() {
        guard !skipped.isEmpty else { return }
        skipped.removeAll()
        analysePending()
    }
}
