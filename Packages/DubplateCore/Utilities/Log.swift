import Foundation
import OSLog

/// Dubplate's logging surface.
///
/// Categories are coarse on purpose — four subsystems is enough to follow a bounce
/// from import to playback in Console.app without instrumenting everything.
public enum Log {
    private static let subsystem = "com.dubplate.app"

    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
