import Foundation

/// The shape of a record. Purely presentational — Dubplate never restricts what
/// you can put in a release, it only changes how the release is described.
public enum ReleaseType: String, CaseIterable, Codable, Sendable {
    case single
    case ep
    case album
    case mixtape
    case project

    public var displayName: String {
        switch self {
        case .single: return "Single"
        case .ep: return "EP"
        case .album: return "Album"
        case .mixtape: return "Mixtape"
        case .project: return "Project"
        }
    }

    /// The number of tracks that usually implies this shape, used only to
    /// pre-select a type when someone drops a folder of bounces on the library.
    public static func inferred(fromTrackCount count: Int) -> ReleaseType {
        switch count {
        case ..<2: return .single
        case 2...6: return .ep
        default: return .album
        }
    }

    /// Sidebar grouping. Mixtapes and projects live together under "All Projects".
    public var isShelvedUnderProjects: Bool {
        self == .mixtape || self == .project
    }
}
