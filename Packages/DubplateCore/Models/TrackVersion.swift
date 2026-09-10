import Foundation
import SwiftData

/// One bounce of a track.
///
/// Versions are deliberately thin: a number, an optional human label, a note and
/// the audio behind them. Dubplate is not source control.
@Model
public final class TrackVersion {
    public var id: UUID = UUID()
    public var versionNumber: Int = 1
    public var label: String?
    public var notes: String?
    public var createdAt: Date = Date.distantPast
    /// When this version was imported *on the device that imported it*, used to
    /// order versions that arrive out of sequence from another device.
    public var importedAt: Date = Date.distantPast

    public var track: Track?

    @Relationship(deleteRule: .nullify)
    public var audioAsset: AudioAsset?

    public init(
        id: UUID = UUID(),
        versionNumber: Int = 1,
        label: String? = nil,
        notes: String? = nil,
        audioAsset: AudioAsset? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.versionNumber = versionNumber
        self.label = label
        self.notes = notes
        self.audioAsset = audioAsset
        self.createdAt = createdAt
        self.importedAt = createdAt
    }

    /// `true` when the owning track points at this version.
    public var isCurrent: Bool {
        track?.currentVersionID == id
    }

    public var audioAssetID: UUID? {
        audioAsset?.id
    }

    /// "v5" — the short form used in dense lists.
    public var shortName: String {
        "v\(versionNumber)"
    }

    /// "v5 — Mix 5" or "v5 — NO SIGNAL 04 mix5.wav".
    public var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(shortName) — \(label)"
        }
        if let filename = audioAsset?.originalFilename {
            return "\(shortName) — \(filename)"
        }
        return shortName
    }

    /// The label a person actually reads in the version list.
    public var listeningLabel: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        return audioAsset.map { FilenameParser.prettyVersionLabel(for: $0.originalFilename) }
            ?? shortName
    }
}
