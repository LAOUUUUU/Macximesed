import Foundation

/// What the person chose in the app's update pop-up, and when that install happens. The app listens for the
/// screen going to sleep and the Mac waking, and asks this whether it's time.
public struct UpdateSchedule: Codable, Sendable, Equatable {
    public enum Timing: String, Codable, Sendable {
        case now
        /// When the screen turns off: the Mac is about to sleep but the network is still up.
        case whenScreenSleeps
        /// Shortly after the Mac wakes, once the network is back.
        case whenMacWakes
        /// Ask again tomorrow (or straight away for a newer version).
        case notNow
    }

    public enum Event: Sendable { case launched, screenSlept, woke }

    public var version: String
    public var timing: Timing
    public var chosen: Date

    public init(version: String, timing: Timing, chosen: Date) {
        self.version = version
        self.timing = timing
        self.chosen = chosen
    }

    public static let none = UpdateSchedule(version: "", timing: .notNow, chosen: .distantPast)

    /// A choice left waiting this long is dropped, and the pop-up asks again.
    public static let keepFor: TimeInterval = 2 * 86_400

    public func isStale(now: Date) -> Bool { now.timeIntervalSince(chosen) > Self.keepFor }

    public func installs(on event: Event, now: Date) -> Bool {
        guard !isStale(now: now) else { return false }
        switch (timing, event) {
        case (.whenScreenSleeps, .screenSlept), (.whenMacWakes, .woke): return true
        default: return false
        }
    }

    /// Whether to show the pop-up for `available`.
    public func shouldAsk(about available: String, now: Date) -> Bool {
        if version.isEmpty || version != available { return true }
        switch timing {
        case .notNow: return now.timeIntervalSince(chosen) >= 86_400
        case .now: return false
        case .whenScreenSleeps, .whenMacWakes: return isStale(now: now)
        }
    }
}
