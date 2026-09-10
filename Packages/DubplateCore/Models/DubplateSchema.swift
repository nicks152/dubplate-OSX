import Foundation
import SwiftData

/// The persistent schema and how it is opened.
///
/// One store, mirrored to the user's private CloudKit database. Everything here is
/// shaped by what CloudKit mirroring supports: no unique constraints, every stored
/// property optional or defaulted, every relationship optional, no `.deny` rules.
/// Documentation/DATA_MODEL.md explains each of those choices.
public enum DubplateSchema {

    /// The iCloud container the applications share. Must match the entitlement in
    /// both application targets.
    public static let cloudContainerIdentifier = "iCloud.com.dubplate.app"

    public static let models: [any PersistentModel.Type] = [
        ArtistProfile.self,
        Release.self,
        Track.self,
        TrackVersion.self,
        AudioAsset.self,
        ArtworkAsset.self
    ]

    public static var schema: Schema {
        Schema(models)
    }

    public enum Storage: Sendable {
        /// On disk, mirrored to CloudKit.
        case synced
        /// On disk, this device only. Used when the person turns sync off.
        case localOnly
        /// Memory only. Used by tests and previews.
        case ephemeral
    }

    public static func container(_ storage: Storage = .synced) throws -> ModelContainer {
        let configuration: ModelConfiguration
        switch storage {
        case .synced:
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private(cloudContainerIdentifier)
            )
        case .localOnly:
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        case .ephemeral:
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Opens the synced store, falling back to a local one when CloudKit cannot be
    /// set up — a missing entitlement in a development build, or an account that
    /// has no iCloud Drive. Dubplate is useful without iCloud; it must not refuse
    /// to launch without it.
    public static func containerWithFallback(preferring storage: Storage = .synced) -> (ModelContainer, DubplateError?) {
        do {
            return (try container(storage), nil)
        } catch {
            Log.library.error("CloudKit store unavailable, falling back to local: \(String(describing: error))")
        }
        do {
            return (try container(.localOnly), DubplateError(.iCloudUnavailable))
        } catch {
            Log.library.error("Local store unavailable, falling back to memory: \(String(describing: error))")
        }
        do {
            return (try container(.ephemeral), DubplateError(.unknown, underlying: nil))
        } catch {
            // A memory-only container cannot realistically fail; if it does there is
            // no library to show and no way to recover inside the process.
            fatalError("Dubplate could not open any store: \(error)")  // swiftcheck:allow
        }
    }
}
