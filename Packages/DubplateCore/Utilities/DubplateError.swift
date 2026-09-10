import Foundation

/// Every failure a person can see, phrased the way Dubplate talks.
///
/// Nothing in the interface is allowed to surface a raw `NSError`, a `CKError` code
/// or an AVFoundation status. Underlying errors are kept for the log only.
public struct DubplateError: LocalizedError, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case unreadableAudio
        case unsupportedFile
        case importFailed
        case fileMissing
        case notDownloadedYet
        case iCloudUnavailable
        case iCloudSignedOut
        case storageFull
        case transferFailed
        case artworkUnreadable
        case playbackFailed
        case unknown
    }

    public let id = UUID()
    public let kind: Kind
    /// The name of the thing that failed, e.g. "Midnight Mix 5.wav".
    public let subject: String?
    /// Preserved for logging. Never shown.
    public let underlying: String?

    public init(_ kind: Kind, subject: String? = nil, underlying: (any Error)? = nil) {
        self.kind = kind
        self.subject = subject
        self.underlying = underlying.map { String(describing: $0) }
    }

    public var title: String {
        switch kind {
        case .unreadableAudio, .playbackFailed:
            return "Dubplate couldn’t play this audio file."
        case .unsupportedFile:
            return "Dubplate doesn’t recognise this kind of file."
        case .importFailed:
            return "Dubplate couldn’t import this file."
        case .fileMissing:
            return "This file isn’t where Dubplate left it."
        case .notDownloadedYet:
            return "This track hasn’t finished syncing to this device yet."
        case .iCloudUnavailable:
            return "iCloud isn’t reachable right now."
        case .iCloudSignedOut:
            return "Sign in to iCloud to sync your releases."
        case .storageFull:
            return "There isn’t enough space to store this."
        case .transferFailed:
            return "That transfer didn’t finish."
        case .artworkUnreadable:
            return "Dubplate couldn’t read this image."
        case .unknown:
            return "Something went wrong."
        }
    }

    public var detail: String {
        switch kind {
        case .unreadableAudio, .playbackFailed:
            return "It may be an unusual format, or the file may be incomplete. Try re-bouncing it as WAV or AIFF."
        case .unsupportedFile:
            return "Dubplate plays WAV, AIFF, CAF, FLAC, ALAC, AAC, M4A and MP3."
        case .importFailed:
            return "Check the file is still on disk, then drag it in again."
        case .fileMissing:
            return "It may have been moved or deleted outside Dubplate. Drop the bounce in again to restore it."
        case .notDownloadedYet:
            return "Dubplate couldn’t fetch it just now. Check your connection, or download the release to keep it on this device."
        case .iCloudUnavailable:
            return "Your work is saved on this device and will sync when iCloud comes back."
        case .iCloudSignedOut:
            return "Dubplate works without iCloud — your releases just stay on this device."
        case .storageFull:
            return "Free up some space, or remove a download you’re finished with."
        case .transferFailed:
            return "Dubplate will try again automatically. You can also retry now."
        case .artworkUnreadable:
            return "Try a JPEG, PNG or HEIC export."
        case .unknown:
            return "Try that again. If it keeps happening, restarting Dubplate usually clears it."
        }
    }

    /// The label on the primary button of the error, if a retry makes sense.
    public var retryTitle: String? {
        switch kind {
        case .transferFailed, .iCloudUnavailable, .notDownloadedYet: return "Try Again"
        case .fileMissing, .importFailed: return "Locate File…"
        default: return nil
        }
    }

    public var errorDescription: String? { title }
    public var failureReason: String? { detail }
}
