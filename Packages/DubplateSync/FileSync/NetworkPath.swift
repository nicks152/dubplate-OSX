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

    /// Latest known path, updated from the monitor's own queue.
    ///
    /// `NWPathMonitor.currentPath` is not meaningful until the first update has
    /// been delivered, and reading it immediately after `start` reports an
    /// unsatisfied path — which made the first download after every launch refuse
    /// itself on the grounds of a cellular connection that was actually Wi-Fi.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var path: NWPath?

        func update(_ newValue: NWPath) {
            lock.lock()
            path = newValue
            lock.unlock()
        }

        var current: NWPath? {
            lock.lock()
            defer { lock.unlock() }
            return path
        }
    }

    private static let state = State()

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            state.update(path)
        }
        monitor.start(queue: DispatchQueue(label: "com.dubplate.network"))
        return monitor
    }()

    /// Starts watching. Called once at launch so the first answer is a real one.
    public static func start() {
        _ = monitor
    }

    /// True on cellular, on a personal hotspot, or on any path the system has marked
    /// as expensive or constrained (Low Data Mode). Unknown counts as unconstrained:
    /// refusing a download because nothing has been measured yet is the worse error.
    public static var isConstrainedOrExpensive: Bool {
        start()
        guard let path = state.current else { return false }
        if path.isExpensive || path.isConstrained { return true }
        return path.usesInterfaceType(.cellular)
    }

    /// True when there is a measured path and it is unusable.
    public static var isOffline: Bool {
        start()
        guard let path = state.current else { return false }
        return path.status != .satisfied
    }
}
