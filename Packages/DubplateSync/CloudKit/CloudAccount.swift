import Foundation
import CloudKit
import DubplateCore

/// Whether iCloud is usable, in the terms the interface needs.
public enum CloudAccountState: String, Sendable {
    case available
    case signedOut
    case restricted
    case temporarilyUnavailable
    case unknown

    public var canSync: Bool { self == .available }

    /// What Dubplate says about it, or nothing when everything is normal.
    public var explanation: DubplateError? {
        switch self {
        case .available: return nil
        case .signedOut: return DubplateError(.iCloudSignedOut)
        case .restricted, .temporarilyUnavailable, .unknown: return DubplateError(.iCloudUnavailable)
        }
    }
}

/// Asks CloudKit about the account, and watches for it changing.
public struct CloudAccount: Sendable {
    private let container: CKContainer

    public init(containerIdentifier: String = DubplateSchema.cloudContainerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    public func state() async -> CloudAccountState {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .signedOut
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .unknown
            @unknown default: return .unknown
            }
        } catch {
            Log.sync.error("Could not read iCloud account status: \(String(describing: error))")
            return .unknown
        }
    }

    /// Fires whenever the person signs in or out of iCloud.
    public static var accountChanges: NotificationCenter.Notifications {
        NotificationCenter.default.notifications(named: .CKAccountChanged)
    }
}
