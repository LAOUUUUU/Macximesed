import Foundation

/// Finds an app by name ("Slack", "Slack.app", any case) in the Applications folders, or takes a path as it is.
public enum AppLocator {
    public static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    public static func find(_ name: String, in roots: [URL] = defaultRoots) -> URL? {
        let fm = FileManager.default
        if name.contains("/") {
            let url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let wanted = (name.lowercased().hasSuffix(".app") ? name : name + ".app").lowercased()
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            if let hit = items.first(where: { $0.lowercased() == wanted }) { return root.appendingPathComponent(hit) }
        }
        return nil
    }

    public static func bundleID(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}

/// A CPU benchmark run with and without Boost. Small differences are noise, and are called that.
public struct BoostMeasurement: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable { case faster, slower, noise }

    public var baseline: Double
    public var boosted: Double
    public static let noiseBand = 3.0

    public init(baseline: Double, boosted: Double) {
        self.baseline = baseline
        self.boosted = boosted
    }

    public var percent: Double { baseline > 0 ? (boosted - baseline) / baseline * 100 : 0 }
    public var verdict: Verdict { abs(percent) < Self.noiseBand ? .noise : percent > 0 ? .faster : .slower }

    /// Work done on `threads` busy threads for `seconds`: iterations per second (a stand-in for a game's load).
    public static func run(seconds: Double, threads: Int) -> Double {
        let counter = Counter()
        let deadline = Date().addingTimeInterval(seconds)
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var x: UInt64 = 0x9E37_79B9_7F4A_7C15
            var local: UInt64 = 0
            while Date() < deadline {
                for _ in 0..<20_000 {
                    x ^= x << 13
                    x ^= x >> 7
                    x ^= x << 17
                }
                local += 1
            }
            counter.add(local &+ (x & 0))
        }
        return Double(counter.total) / seconds
    }

    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var total: UInt64 = 0
        func add(_ n: UInt64) { lock.withLock { total += n } }
    }
}
