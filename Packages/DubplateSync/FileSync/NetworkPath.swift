import Foundation
import Network
import DubplateCore

/// Whether this device is currently on a connection worth sending a gigabyte over.
///
/// Exists so that "Download over cellular" is a switch that does something. A
/// producer who turns it off and then loses a month of data allowance to a 96/24
/// album will not turn it back on, and will not trust anything else the application
/// says either.
public enum NetworkPath {
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.dubplate.network"))
        return monitor
    }()

    /// True on cellular, on a personal hotspot, or on any path the system has marked
    /// as expensive or constrained (Low Data Mode).
    public static var isConstrainedOrExpensive: Bool {
        let path = monitor.currentPath
        if path.isExpensive || path.isConstrained { return true }
        return path.usesInterfaceType(.cellular)
    }

    /// True when there is no usable path at all.
    public static var isOffline: Bool {
        monitor.currentPath.status != .satisfied
    }
}
