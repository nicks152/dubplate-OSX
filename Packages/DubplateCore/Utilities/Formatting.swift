import Foundation

/// Number and duration formatting used across both applications.
///
/// These are the only places durations and byte counts are turned into text, so
/// "3:42" looks the same in the Mac track list and on the iPhone Lock Screen.
public enum Formatting {
    /// "3:42", "1:04:11". Negative and non-finite values render as "--:--".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "42 minutes", "1 hour 14 minutes" — used for release run times.
    public static func longDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours) hour\(hours == 1 ? "" : "s")")
        }
        if minutes > 0 || hours == 0 {
            parts.append("\(max(minutes, 1)) minute\(minutes == 1 ? "" : "s")")
        }
        return parts.joined(separator: " ")
    }

    /// "1.2 GB", "480 MB", "Nothing yet".
    public static func fileSize(_ bytes: Int64) -> String {
        // Not "Zero KB". A record whose sizes have not been recorded reads that
        // line as a measurement, and it is not one.
        guard bytes > 0 else { return "Nothing yet" }
        return bytes.formatted(.byteCount(style: .file))
    }

    /// "2 hours ago", "yesterday", "last week" — used in the inbox and recently
    /// played. `RelativeDateTimeFormatter` names only the units it has names for,
    /// so there is no weekday among them.
    public static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
