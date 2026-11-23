import Foundation

/// How much can go wrong. Higher tiers ask more before acting.
public enum Tier: String, CaseIterable, Sendable, Codable {
    case safe, medium, risky, extreme
}

public struct RunningApp: Sendable, Equatable {
    public var name: String
    public var bundleID: String?

    public init(name: String, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }
}

public struct CleanupItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var tier: Tier
    public var paths: [URL]
    public var bytes: UInt64
    /// Name of a running app that probably owns this, so moving it now could upset that app.
    public var inUseBy: String?
}

public enum CleanupCatalog {
    /// Things that are rebuilt automatically when needed. Apple's own caches, `~/.cache` (often
    /// virtual environments and runtimes) and Macximesed's own data are never included.
    public static func safe(home: URL, running: [RunningApp]) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let fm = FileManager.default

        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        for name in children(of: caches).map(\.lastPathComponent).sorted() {
            if isAppleOwned(name) || name == "Macximesed" || name.hasPrefix(".") { continue }
            let url = caches.appendingPathComponent(name, isDirectory: true)
            let bytes = allocatedSize(of: url)
            guard bytes > 0 else { continue }
            items.append(CleanupItem(
                id: "cache:\(name)", title: "\(name) cache", tier: .safe, paths: [url],
                bytes: bytes, inUseBy: owner(of: name, running: running)
            ))
        }

        func group(_ id: String, _ title: String, _ dir: String) {
            let kids = children(of: home.appendingPathComponent(dir, isDirectory: true))
            let bytes = kids.reduce(0) { $0 + allocatedSize(of: $1) }
            guard !kids.isEmpty, bytes > 0 else { return }
            items.append(CleanupItem(id: id, title: title, tier: .safe, paths: kids, bytes: bytes, inUseBy: nil))
        }
        group("logs:user", "Your app logs and crash reports", "Library/Logs")
        group("xcode:derived-data", "Xcode build data (DerivedData)", "Library/Developer/Xcode/DerivedData")
        group("xcode:device-support", "Xcode iOS device support files", "Library/Developer/Xcode/iOS DeviceSupport")
        group("simulator:caches", "Simulator caches", "Library/Developer/CoreSimulator/Caches")

        let npm = home.appendingPathComponent(".npm/_cacache", isDirectory: true)
        let npmBytes = allocatedSize(of: npm)
        if fm.fileExists(atPath: npm.path), npmBytes > 0 {
            items.append(CleanupItem(id: "npm:cache", title: "npm download cache", tier: .safe, paths: [npm],
                                     bytes: npmBytes, inUseBy: nil))
        }
        return items
    }

    /// `only` empty means everything. Items in use are left out unless asked for.
    public static func select(_ items: [CleanupItem], only: Set<String>, includeInUse: Bool) -> [CleanupItem] {
        items.filter { item in
            (only.isEmpty || only.contains(item.id)) && (item.inUseBy == nil || includeInUse)
        }
    }

    /// Moves the items into the undo store. Nothing is deleted.
    public static func run(_ items: [CleanupItem], store: UndoStore) throws -> UndoBatch {
        let ids = items.map(\.id).joined(separator: ", ")
        return try store.stash(items.flatMap(\.paths), reason: "clean: \(ids)")
    }

    // MARK: - Helpers

    static func children(of dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0 != ".DS_Store" }.sorted().map { dir.appendingPathComponent($0) }
    }

    /// Apple framework and daemon caches that don't use the `com.apple.` prefix. Left alone even
    /// though most are rebuilt, because some (CloudKit, FamilyCircle) hold sync state.
    static let appleCacheNames: Set<String> = [
        "AMSDataMigratorTool", "Animoji", "CloudKit", "FamilyCircle", "GameKit", "GeoServices",
        "PassKit", "softwareupdate", "ssu", "tvapp_bag", "INSTALLATION", "Favicons",
        "familycircled", "PhotoAnalysis", "SiriTTS",
    ]

    static func isAppleOwned(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix("PFScene") || appleCacheNames.contains(name)
    }

    /// Matches a cache folder name against running apps by bundle ID, by name without spaces,
    /// or by the first word of the name. A false match only means the item is skipped.
    static func owner(of folder: String, running: [RunningApp]) -> String? {
        let f = folder.lowercased()
        for app in running where !(app.bundleID?.hasPrefix("com.apple.") ?? false) {
            var tokens: [String] = []
            if let id = app.bundleID?.lowercased() { tokens.append(id) }
            let name = app.name.lowercased()
            tokens.append(name.replacingOccurrences(of: " ", with: ""))
            if let first = name.split(separator: " ").first, first.count >= 4 { tokens.append(String(first)) }
            if tokens.contains(where: { !$0.isEmpty && (f == $0 || f.contains($0)) }) { return app.name }
        }
        return nil
    }
}
