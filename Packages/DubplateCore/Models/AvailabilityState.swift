import Foundation

/// Where a piece of media currently lives relative to *this* device.
///
/// Dubplate deliberately keeps this vocabulary small: the interface only ever
/// says what a person can do right now, never what the transport layer is doing.
public enum AvailabilityState: String, CaseIterable, Codable, Sendable {
    /// Imported on this device and never uploaded (no iCloud account, or sync off).
    case local
    /// Uploaded, but the bytes are not on this device yet.
    case cloudOnly
    /// Bytes are arriving.
    case downloading
    /// Present on this device and known to the cloud.
    case available
    /// The record exists but the file behind it cannot be found.
    case missing
    /// The last transfer failed in a way that needs a retry.
    case error

    /// Whether audio in this state can start playing immediately.
    public var isPlayableNow: Bool {
        self == .local || self == .available
    }

    /// Where a file that is not here is, phrased for the device asking.
    ///
    /// A phone says the record is on the Mac; a Mac cannot, because it is the Mac.
    public static var elsewhereDescription: String {
        #if os(iOS)
        return "Available on your Mac"
        #else
        return "Available on your other device"
        #endif
    }

    /// Copy shown next to a track when it cannot be played. `nil` means "say nothing".
    public var listenerExplanation: String? {
        switch self {
        case .local, .available:
            return nil
        case .cloudOnly:
            return Self.elsewhereDescription
        case .downloading:
            return "Downloading"
        case .missing:
            return "File not found"
        case .error:
            return "Couldn’t download"
        }
    }
}
