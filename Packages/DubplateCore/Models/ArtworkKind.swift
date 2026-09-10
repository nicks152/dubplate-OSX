import Foundation

/// The three visual roles artwork can play in a release.
public enum ArtworkKind: String, CaseIterable, Codable, Sendable {
    /// The square cover.
    case staticArtwork
    /// A short looping visual for the whole release.
    case animatedArtwork
    /// A vertical looping visual attached to a single track.
    case trackVideo

    public var isVideo: Bool {
        self != .staticArtwork
    }

    public var displayName: String {
        switch self {
        case .staticArtwork: return "Cover"
        case .animatedArtwork: return "Release Motion"
        case .trackVideo: return "Track Canvas"
        }
    }
}
