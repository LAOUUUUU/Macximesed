import CoreServices
import Foundation

// MARK: - Architectures

public enum AppArch: String, Sendable, Equatable, Comparable, Codable {
    case arm64, x86_64

    public static func < (a: AppArch, b: AppArch) -> Bool { a.rawValue < b.rawValue }

    /// How the app runs on Apple silicon.
    public static func kind(_ archs: [AppArch]) -> String {
        switch (archs.contains(.arm64), archs.contains(.x86_64)) {
        case (true, true): "Universal"
        case (true, false): "Apple silicon"
        case (false, true): "Intel (Rosetta)"
        case (false, false): "unknown"
        }
    }
}

/// Reads the CPU types out of a Mach-O header (thin or universal). Only the first few hundred bytes are needed.
public enum MachO {
    static let cpuARM64: UInt32 = 0x0100_000C
    static let cpuX86_64: UInt32 = 0x0100_0007

    public static func architectures(of data: Data) -> [AppArch] {
        guard data.count >= 8 else { return [] }
        let bytes = [UInt8](data.prefix(4096))
        func le(_ o: Int) -> UInt32 { o + 4 <= bytes.count ? UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 : 0 }
        func be(_ o: Int) -> UInt32 { o + 4 <= bytes.count ? UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]) : 0 }
        func arch(_ cpu: UInt32) -> AppArch? {
            switch cpu {
            case cpuARM64: .arm64
            case cpuX86_64: .x86_64
            default: nil
            }
        }

        switch be(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF: // universal, 32- or 64-bit offsets
            let entrySize = be(0) == 0xCAFE_BABF ? 32 : 20
            let count = Int(min(be(4), 16))
            let found = (0..<count).compactMap { arch(be(8 + $0 * entrySize)) }
            return Array(Set(found)).sorted()
        case 0xCFFA_EDFE: // thin 64-bit, little-endian (read as big-endian)
            return arch(le(4)).map { [$0] } ?? []
        default:
            return []
        }
    }

    public static func architectures(ofFile url: URL) -> [AppArch] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        return architectures(of: (try? handle.read(upToCount: 4096)) ?? Data())
    }
}

// MARK: - Apps

public struct AppInfo: Sendable, Equatable {
    public var url: URL
    public var bundleID: String
    public var name: String
    public var version: String?
    public var bytes: UInt64
    public var architectures: [AppArch]
    /// From Spotlight. Nil means unknown, which is never treated as "unused".
    public var lastUsed: Date?
    public var isApple: Bool
    public var fromAppStore: Bool
    /// True when `lastUsed` was estimated from the app's own files because Spotlight had no date.
    public var lastUsedIsEstimate: Bool

    public init(url: URL, bundleID: String, name: String, version: String?, bytes: UInt64,
                architectures: [AppArch], lastUsed: Date?, isApple: Bool, fromAppStore: Bool,
                lastUsedIsEstimate: Bool = false) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.bytes = bytes
        self.architectures = architectures
        self.lastUsed = lastUsed
        self.isApple = isApple
        self.fromAppStore = fromAppStore
        self.lastUsedIsEstimate = lastUsedIsEstimate
    }

    public var isOnSystemVolume: Bool { url.path.hasPrefix("/System/") }
}

public enum AppScanner {
    public static var defaultFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// Finds `.app` bundles directly in each folder and one plain folder down (e.g. `/Applications/Vendor/Tool.app`).
    /// `home`, when given, is used to estimate the last use of apps Spotlight has no date for.
    public static func scan(_ folders: [URL], lastUsed: (URL) -> Date? = spotlightLastUsed, home: URL? = nil) -> [AppInfo] {
        var found: [URL] = []
        for folder in folders {
            for child in CleanupCatalog.children(of: folder) {
                if child.pathExtension == "app" {
                    found.append(child)
                } else if isPlainFolder(child) {
                    found += CleanupCatalog.children(of: child).filter { $0.pathExtension == "app" }
                }
            }
        }
        return found.compactMap { url -> AppInfo? in
            guard var app = read(url, lastUsed: lastUsed) else { return nil }
            if app.lastUsed == nil, let home, let estimate = estimateLastUse(app, home: home) {
                app.lastUsed = estimate
                app.lastUsedIsEstimate = true
            }
            return app
        }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func unused(_ apps: [AppInfo], olderThanDays days: Int, now: Date = Date()) -> [AppInfo] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return apps.filter { ($0.lastUsed.map { $0 < cutoff }) ?? false }
    }

    static func read(_ app: URL, lastUsed: (URL) -> Date?) -> AppInfo? {
        let contents = app.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String else { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let archs = (info["CFBundleExecutable"] as? String).map {
            MachO.architectures(ofFile: contents.appendingPathComponent("MacOS/\($0)"))
        } ?? []
        let receipt = contents.appendingPathComponent("_MASReceipt/receipt")
        return AppInfo(
            url: app, bundleID: id, name: name, version: info["CFBundleShortVersionString"] as? String,
            bytes: allocatedSize(of: app), architectures: archs, lastUsed: lastUsed(app),
            isApple: id.hasPrefix("com.apple."),
            fromAppStore: FileManager.default.fileExists(atPath: receipt.path)
        )
    }

    /// A folder that isn't itself an app. Names may contain dots ("Packet Tracer 9.0.1").
    static func isPlainFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            && url.pathExtension != "app"
    }

    /// Newest change date among the app's own files (settings, saved state, support folders and
    /// their direct contents). Apps write these while running, so it's a fair guess at the last use.
    static func estimateLastUse(_ app: AppInfo, home: URL) -> Date? {
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        var dates: [Date] = []
        for path in AppLeftovers.find(for: app, home: home) {
            if let d = modified(path) { dates.append(d) }
            dates += CleanupCatalog.children(of: path).compactMap(modified)
        }
        return dates.max()
    }

    /// Spotlight's "Last opened" date.
    public static func spotlightLastUsed(_ app: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, app as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: - Leftovers

public struct OrphanGroup: Sendable, Equatable {
    public var id: String
    public var paths: [URL]
    public var bytes: UInt64
}

public enum AppLeftovers {
    /// Library folders apps write to, and whether entries there are named after the bundle ID, the app name, or both.
    static let byID = [
        "Library/Application Support", "Library/Caches", "Library/HTTPStorages", "Library/WebKit",
        "Library/Containers", "Library/Application Scripts", "Library/Logs",
    ]
    static let byName = ["Library/Application Support", "Library/Logs", "Library/Caches"]

    /// Files in the home Library that belong to this app. Matches are exact (or `<id>.` prefixes for
    /// plists, saved state and launch agents), so `com.example.gamepad` never matches `com.example.game`.
    public static func find(for app: AppInfo, home: URL) -> [URL] {
        let fm = FileManager.default
        let id = app.bundleID
        var out: [URL] = []
        func add(_ url: URL) { if fm.fileExists(atPath: url.path), !out.contains(url) { out.append(url) } }

        for dir in byID { add(home.appendingPathComponent(dir).appendingPathComponent(id)) }
        // Names like "Game" are only used when they're specific enough to be safe.
        if app.name.count >= 4, !app.isApple {
            for dir in byName { add(home.appendingPathComponent(dir).appendingPathComponent(app.name)) }
        }
        let prefixed: [(String, String)] = [
            ("Library/Preferences", "\(id).plist"),
            ("Library/Saved Application State", "\(id).savedState"),
        ]
        for (dir, name) in prefixed { add(home.appendingPathComponent(dir).appendingPathComponent(name)) }
        for (dir, prefix) in [("Library/Preferences/ByHost", "\(id)."), ("Library/LaunchAgents", "\(id).")] {
            let folder = home.appendingPathComponent(dir)
            for child in CleanupCatalog.children(of: folder) where child.lastPathComponent.hasPrefix(prefix) {
                add(child)
            }
        }
        return out
    }

    /// `com.example.game.plist` → `com.example`. Nil for names that aren't reverse-DNS.
    static func vendor(of name: String) -> String? {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, ["com", "org", "net", "io", "app", "dev", "co", "me", "ru", "de", "fr", "uk"].contains(parts[0]) else {
            return nil
        }
        // io.github.<user>.<tool>: the user is part of the vendor.
        if parts.count >= 4, parts[1] == "github" || parts[1] == "gitlab" { return parts.prefix(3).joined(separator: ".") }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Reverse-DNS entries whose vendor has no installed app. Plain names are skipped: there's no way to tell who owns them.
    public static func orphans(home: URL, installedBundleIDs: [String]) -> [OrphanGroup] {
        let vendors = Set(installedBundleIDs.compactMap { vendor(of: $0 + ".x") })
        var groups: [String: [URL]] = [:]
        let dirs = Set(byID + ["Library/Preferences", "Library/Saved Application State"])
        for dir in dirs {
            for child in CleanupCatalog.children(of: home.appendingPathComponent(dir)) {
                var name = child.lastPathComponent
                for ext in [".plist", ".savedState"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
                guard !name.hasPrefix("com.apple."), let v = vendor(of: name), !vendors.contains(v) else { continue }
                groups[name, default: []].append(child)
            }
        }
        return groups.map { OrphanGroup(id: $0.key, paths: $0.value.sorted { $0.path < $1.path },
                                        bytes: $0.value.reduce(0) { $0 + allocatedSize(of: $1) }) }
            .sorted { $0.id < $1.id }
    }
}

// MARK: - Uninstall

public enum UninstallError: Error, Equatable {
    case systemApp
    case appleApp
    case running(String)
}

public struct UninstallPlan: Sendable, Equatable {
    public var app: AppInfo
    /// The app first, then its leftovers.
    public var paths: [URL]
    public var bytes: UInt64
}

public enum AppUninstaller {
    public static func plan(_ app: AppInfo, home: URL, running: [RunningApp]) throws -> UninstallPlan {
        if app.isOnSystemVolume { throw UninstallError.systemApp }
        // Apple's App Store apps (GarageBand, iMovie, Pages...) can be downloaded again; built-in ones can't.
        if app.isApple, !app.fromAppStore { throw UninstallError.appleApp }
        if let r = running.first(where: { $0.bundleID == app.bundleID }) { throw UninstallError.running(r.name) }
        let leftovers = AppLeftovers.find(for: app, home: home)
        return UninstallPlan(app: app, paths: [app.url] + leftovers,
                             bytes: app.bytes + leftovers.reduce(0) { $0 + allocatedSize(of: $1) })
    }

    public static func run(_ plan: UninstallPlan, store: UndoStore) throws -> UndoBatch {
        try store.stash(plan.paths, reason: "uninstall: \(plan.app.name) (\(plan.app.bundleID))")
    }
}
