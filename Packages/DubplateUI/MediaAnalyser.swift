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

    private func run(limit: Int) async {
        let wantsLoudness = settings.measuresLoudness
        var descriptor = FetchDescriptor<AudioAsset>(
            predicate: wantsLoudness
                ? #Predicate { $0.waveformPeaks == nil || $0.integratedLoudness == nil }
                : #Predicate { $0.waveformPeaks == nil }
        )
        // Without a limit this hydrates every unanalysed asset in the library on the
        // main actor to take the first forty.
        descriptor.fetchLimit = limit
        let assets = (try? context.fetch(descriptor)) ?? []
        guard !assets.isEmpty else { return }

        for asset in assets {
            if Task.isCancelled { return }
            guard !asset.isDeleted,
                  mediaStore.exists(relativePath: asset.relativePath)
            else { continue }

            let url = mediaStore.url(forRelativePath: asset.relativePath)
            if asset.waveformPeaks == nil {
                if let peaks = try? await WaveformGenerator().peaks(forFileAt: url), !peaks.isEmpty {
                    guard !asset.isDeleted else { continue }
                    asset.waveformPeaks = peaks
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
            // Give the main actor room between files: this is background work and
            // must never make a scroll stutter.
            await Task.yield()
        }
        // Keep going: analysis used to stop silently after the first batch.
        if !Task.isCancelled {
            await run(limit: limit)
        }
    }
}
