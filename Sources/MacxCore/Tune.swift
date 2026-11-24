import Foundation

/// The Medium tier: settings that make the Mac lighter, each reversible. Every applied tweak has its own
/// ledger (`~/Library/Application Support/Macximesed/Tune/<id>.json`) holding the value it replaced.
public enum Tune {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case appleAgent(String)
        case badLabel(String)

        public var description: String {
            switch self {
            case .unknown(let id): "No tweak called \(id). See: macx tune"
            case .appleAgent(let l): "\(l) is one of macOS's own; turning those off belongs to the Risky tier."
            case .badLabel(let l): "\"\(l)\" isn't a launch agent label."
            }
        }
    }

    public struct Tweak: Sendable {
        public var id: String
        public var title: String
        public var why: String
        public var domain: String
        public var key: String
        public var value: PlistValue
        /// Something to restart so the change shows (Dock, say).
        public var refresh: [String]?
    }

    public static let catalog: [Tweak] = [
        Tweak(
            id: "reduce-transparency", title: "Reduce Transparency", why: "solid window backgrounds: less blur work for the GPU",
            domain: "com.apple.universalaccess", key: "reduceTransparency", value: .bool(true)),
        Tweak(
            id: "reduce-motion", title: "Reduce Motion", why: "fewer animations when switching spaces and opening apps",
            domain: "com.apple.universalaccess", key: "reduceMotion", value: .bool(true)),
        Tweak(
            id: "no-window-animations", title: "No window opening animations", why: "windows appear at once",
            domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", value: .bool(false)),
        Tweak(
            id: "fast-window-resize", title: "Instant window resizing", why: "sheets and resizes without the slow-down",
            domain: "NSGlobalDomain", key: "NSWindowResizeTime", value: .double(0.001)),
        Tweak(
            id: "dock-no-launch-bounce", title: "No Dock launch bounce", why: "the Dock doesn't animate app launches",
            domain: "com.apple.dock", key: "launchanim", value: .bool(false), refresh: ["/usr/bin/killall", "Dock"]),
    ]

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/Tune")
    }

    static func ledgerFile(_ id: String, in folder: URL) -> URL {
        folder.appendingPathComponent(id.replacingOccurrences(of: ":", with: "_") + ".json")
    }

    /// Third-party launch agent labels only: reverse-DNS-ish, no spaces or shell characters, never com.apple.
    static func agentLabel(_ id: String) throws -> String? {
        guard id.hasPrefix("agent:") else { return nil }
        let label = String(id.dropFirst(6))
        guard label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{2,200}$"#, options: .regularExpression) != nil else {
            throw Problem.badLabel(label)
        }
        guard !label.hasPrefix("com.apple.") else { throw Problem.appleAgent(label) }
        return label
    }

    public static func apply(_ ids: [String], folder: URL = defaultFolder, uid: uid_t, system: SystemControl = RealSystem()) throws {
        // Check everything first, so a bad name changes nothing.
        for id in ids where try agentLabel(id) == nil && !catalog.contains(where: { $0.id == id }) { throw Problem.unknown(id) }
        for id in ids {
            let file = ledgerFile(id, in: folder)
            guard TweakLedger.load(at: file) == nil else { continue }
            var ledger = try TweakLedger.open(at: file, purpose: "tune:\(id)")
            if let label = try agentLabel(id) {
                try ledger.runCommand(
                    ["/bin/launchctl", "disable", "gui/\(uid)/\(label)"], undo: ["/bin/launchctl", "enable", "gui/\(uid)/\(label)"],
                    system: system)
            } else if let t = catalog.first(where: { $0.id == id }) {
                try ledger.setDefault(domain: t.domain, key: t.key, to: t.value, system: system)
                if let r = t.refresh { try? system.run(r) }
            }
            if ledger.changes.isEmpty { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Undo the named tweaks, or all of them (nil).
    public static func undo(_ ids: [String]?, folder: URL = defaultFolder, system: SystemControl = RealSystem()) throws
        -> TweakLedger.RestoreReport
    {
        var restored: [TweakLedger.Change] = []
        var failed: [(TweakLedger.Change, String)] = []
        for id in ids ?? applied(folder: folder) {
            guard let l = TweakLedger.load(at: ledgerFile(id, in: folder)) else { continue }
            let r = l.restore(system: system)
            restored += r.restored
            failed += r.failed
            if let t = catalog.first(where: { $0.id == id }), let refresh = t.refresh { try? system.run(refresh) }
        }
        return TweakLedger.RestoreReport(restored: restored, failed: failed)
    }

    public static func applied(folder: URL = defaultFolder) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.map {
            $0.hasPrefix("agent_") ? "agent:" + $0.dropFirst(6) : $0
        }.sorted()
    }
}
