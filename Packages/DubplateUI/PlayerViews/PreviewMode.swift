import SwiftUI

/// The three ways Dubplate presents a record.
///
/// These are Dubplate's own environments, not imitations of anyone else's player.
/// They exist so a producer can hear what a record feels like in the three shapes
/// modern listening actually takes: something dense and dark you glance at, something
/// spacious you sit with, and something that is mostly moving image.
public enum PreviewMode: String, CaseIterable, Identifiable, Sendable {
    /// Dark, compact, contemporary.
    case stream
    /// Artwork-forward and editorial.
    case gallery
    /// Built around a looping visual.
    case motion

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stream: return "Stream"
        case .gallery: return "Gallery"
        case .motion: return "Motion"
        }
    }

    public var explanation: String {
        switch self {
        case .stream: return "Dense and dark. How most people will glance at it."
        case .gallery: return "Spacious and editorial. How it feels when someone sits with it."
        case .motion: return "Full-screen visual. How it feels on a phone held up."
        }
    }
}
