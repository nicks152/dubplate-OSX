import Foundation
import SwiftData

/// The owner of this library. Dubplate has no accounts — this is simply the name
/// that new releases are credited to by default.
@Model
public final class ArtistProfile {
    public var id: UUID = UUID()
    public var displayName: String = ""
    public var defaultArtistName: String = ""
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast

    @Relationship(deleteRule: .nullify)
    public var avatar: ArtworkAsset?

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        defaultArtistName: String = "",
        avatar: ArtworkAsset? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultArtistName = defaultArtistName
        self.avatar = avatar
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
