import CoreServices
import Foundation

// MARK: - Architectures

public enum AppArch: String, Sendable, Equatable, Comparable, Codable {
    case arm64, x86_64

    public static func < (a: AppArch, b: AppArch) -> Bool { a.rawValue < b.rawValue }

    /// The CPU this Mac has.
    public static var hostIsARM: Bool {
        #if arch(arm64)
            true
        #else
            // An Intel build can still be running under Rosetta on Apple silicon.
            var translated: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        #endif
    }

    /// How the app runs on this Mac.
    public static func kind(_ archs: [AppArch], hostIsARM: Bool = AppArch.hostIsARM) -> String {
        switch (archs.contains(.arm64), archs.contains(.x86_64), hostIsARM) {
        case (true, true, _): "Universal"
        case (true, false, true): "Apple silicon"
        case (true, false, false): "Apple silicon only (can't run here)"
        case (false, true, true): "Intel (Rosetta)"
        case (false, true, false): "Intel"
        case (false, false, _): "unknown"
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
        func le(_ o: Int) -> UInt32 {
            o + 4 <= bytes.count
                ? UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 : 0
        }
        func be(_ o: Int) -> UInt32 {
            o + 4 <= bytes.count
                ? UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]) : 0
        }
        func arch(_ cpu: UInt32) -> AppArch? {
            switch cpu {
            case cpuARM64: .arm64
            case cpuX86_64: .x86_64
            default: nil
            }
        }

        switch be(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:  // universal, 32- or 64-bit offsets
            let entrySize = be(0) == 0xCAFE_BABF ? 32 : 20
            let count = Int(min(be(4), 16))
            let found = (0..<count).compactMap { arch(be(8 + $0 * entrySize)) }
            return Array(Set(found)).sorted()
        case 0xCFFA_EDFE:  // thin 64-bit, little-endian (read as big-endian)
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

public struct AppDiscovery: Sendable {
    public var apps: [AppInfo]
    /// Apps found in privacy-guarded folders and left unread (no Full Disk Access).
    public var skippedGuarded: Int
}

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

    public init(
        url: URL, bundleID: String, name: String, version: String?, bytes: UInt64,
        architectures: [AppArch], lastUsed: Date?, isApple: Bool, fromAppStore: Bool,
        lastUsedIsEstimate: Bool = false
    ) {
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
    /// Used only when Spotlight can't answer: the standard app folders, plus `Applications` on every mounted volume.
    public static var fallbackFolders: [URL] {
        var out = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path != "/" {
            out.append(v.appendingPathComponent("Applications"))
        }
        return out
    }

    /// Every app on the Mac, wherever it is: asks Spotlight, falls back to scanning folders. Apps in
    /// privacy-guarded folders (Documents, Desktop, external disks...) are skipped and counted unless
    /// the policy allows them, so listing apps never causes a privacy prompt.
    public static func discover(
        includeSystem: Bool = false, runner: CommandRunner = ProcessRunner(),
        lastUsed: (URL) -> Date? = spotlightLastUsed, home: URL? = nil, policy: PrivacyPolicy = .current
    ) -> AppDiscovery {
        if let out = try? runner.run("/usr/bin/mdfind", ["kMDItemContentTypeTree == 'com.apple.application-bundle'"]) {
            let (urls, skipped) = split(parseAppPaths(out, includeSystem: includeSystem), policy: policy)
            if !urls.isEmpty {
                return AppDiscovery(apps: build(urls, lastUsed: lastUsed, home: home, policy: policy), skippedGuarded: skipped)
            }
        }
        var folders = fallbackFolders
        if includeSystem { folders.append(URL(fileURLWithPath: "/System/Applications")) }
        let (allowed, skipped) = split(folders, policy: policy)
        return AppDiscovery(apps: scan(allowed, lastUsed: lastUsed, home: home, policy: policy), skippedGuarded: skipped)
    }

    /// Splits paths into ones that are safe to read and a count of guarded ones.
    public static func split(_ urls: [URL], policy: PrivacyPolicy) -> (kept: [URL], skipped: Int) {
        let kept = urls.filter { policy.allows($0) }
        return (kept, urls.count - kept.count)
    }

    /// Keeps standalone apps: drops apps inside other bundles, in a Library folder (helpers), in the Trash,
    /// and on the system volume unless asked.
    public static func parseAppPaths(_ out: String, includeSystem: Bool = false) -> [URL] {
        out.split(separator: "\n").map(String.init).filter { path in
            guard path.hasSuffix(".app") else { return false }
            let parent = (path as NSString).deletingLastPathComponent
            let parts = parent.split(separator: "/")
            if parts.contains(where: { $0.hasSuffix(".app") || $0 == "Library" || $0 == ".Trash" }) { return false }
            if path.hasPrefix("/System/") { return includeSystem }
            return true
        }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Finds `.app` bundles directly in each folder and one plain folder down (e.g. `/Applications/Vendor/Tool.app`).
    /// `home`, when given, is used to estimate the last use of apps Spotlight has no date for.
    public static func scan(
        _ folders: [URL], lastUsed: (URL) -> Date? = spotlightLastUsed, home: URL? = nil, policy: PrivacyPolicy = .current
    ) -> [AppInfo] {
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
        return build(found, lastUsed: lastUsed, home: home, policy: policy)
    }

    static func build(_ found: [URL], lastUsed: (URL) -> Date?, home: URL?, policy: PrivacyPolicy) -> [AppInfo] {
        found.compactMap { url -> AppInfo? in
            guard var app = read(url, lastUsed: lastUsed) else { return nil }
            if app.lastUsed == nil, let home, let estimate = estimateLastUse(app, home: home, policy: policy) {
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
            let id = info["CFBundleIdentifier"] as? String
        else { return nil }
        let name =
            (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let archs =
            (info["CFBundleExecutable"] as? String).map {
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
    static func estimateLastUse(_ app: AppInfo, home: URL, policy: PrivacyPolicy) -> Date? {
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        var dates: [Date] = []
        for path in AppLeftovers.find(for: app, home: home, policy: policy) {
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
    /// Library folders where apps keep files named exactly after their bundle ID.
    static let byID = [
        "Library/Application Support", "Library/Caches", "Library/HTTPStorages", "Library/WebKit",
        "Library/Containers", "Library/Application Scripts", "Library/Logs",
    ]
    static let byName = ["Library/Application Support", "Library/Logs", "Library/Caches"]

    /// Files in the home Library that belong to this app by its bundle ID: exact names, plus
    /// `<id>.` prefixes for preferences, saved state and launch agents. `com.example.gamepad`
    /// never matches `com.example.game`.
    public static func find(for app: AppInfo, home: URL, policy: PrivacyPolicy = .current) -> [URL] {
        let fm = FileManager.default
        let id = app.bundleID
        var out: [URL] = []
        func add(_ url: URL) {
            if policy.allows(url), fm.fileExists(atPath: url.path), !out.contains(url) { out.append(url) }
        }

        for dir in byID { add(home.appendingPathComponent(dir).appendingPathComponent(id)) }
        add(home.appendingPathComponent("Library/Preferences").appendingPathComponent("\(id).plist"))
        add(home.appendingPathComponent("Library/Saved Application State").appendingPathComponent("\(id).savedState"))
        for (dir, prefix) in [("Library/Preferences/ByHost", "\(id)."), ("Library/LaunchAgents", "\(id).")] {
            for child in CleanupCatalog.children(of: home.appendingPathComponent(dir)) where child.lastPathComponent.hasPrefix(prefix) {
                add(child)
            }
        }
        return out
    }

    /// Folders named exactly like the app ("Application Support/Steam"). Another program could use
    /// the same name, so these are only included when asked for.
    public static func nameMatches(for app: AppInfo, home: URL, policy: PrivacyPolicy = .current) -> [URL] {
        guard !app.isApple else { return [] }
        return byName.map { home.appendingPathComponent($0).appendingPathComponent(app.name) }
            .filter { policy.allows($0) && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Entries named like a bundle ID (`com.vendor.app`, `com.vendor.app.plist`) that no bundle on
    /// this Mac owns and that take up space. Plain names ("SomeFolder") are never listed: there's no way to know who owns them.
    public static func orphans(home: URL, bundles: BundleIndex, policy: PrivacyPolicy = .current) -> [OrphanGroup] {
        var groups: [String: [URL]] = [:]
        let dirs = Set(byID + ["Library/Preferences", "Library/Saved Application State"])
        for dir in dirs where policy.allows(home.appendingPathComponent(dir)) {
            for child in CleanupCatalog.children(of: home.appendingPathComponent(dir)) {
                let name = ReverseDNS.baseName(child.lastPathComponent)
                // App-group IDs (group.*, systemgroup.*) are sharing permissions, not bundle IDs, so no bundle owns them by name.
                guard ReverseDNS.isReverseDNS(name), !name.hasPrefix("com.apple."),
                    !name.hasPrefix("group."), !name.hasPrefix("systemgroup."),
                    bundles.owner(of: name) == nil
                else { continue }
                groups[name, default: []].append(child)
            }
        }
        return groups.map {
            OrphanGroup(
                id: $0.key, paths: $0.value.sorted { $0.path < $1.path },
                bytes: $0.value.reduce(0) { $0 + allocatedSize(of: $1) })
        }
        .filter { $0.bytes > 0 }
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
    public static func plan(
        _ app: AppInfo, home: URL, runningBundleIDs: Set<String>,
        includeNameMatches: Bool = false
    ) throws -> UninstallPlan {
        if app.isOnSystemVolume { throw UninstallError.systemApp }
        // Apple's App Store apps (GarageBand, iMovie, Pages...) can be downloaded again; built-in ones can't.
        if app.isApple, !app.fromAppStore { throw UninstallError.appleApp }
        if runningBundleIDs.contains(app.bundleID) { throw UninstallError.running(app.name) }
        var leftovers = AppLeftovers.find(for: app, home: home)
        if includeNameMatches { leftovers += AppLeftovers.nameMatches(for: app, home: home).filter { !leftovers.contains($0) } }
        return UninstallPlan(
            app: app, paths: [app.url] + leftovers,
            bytes: app.bytes + leftovers.reduce(0) { $0 + allocatedSize(of: $1) })
    }

    public static func run(_ plan: UninstallPlan, store: UndoStore) throws -> UndoBatch {
        try store.stash(plan.paths, reason: "uninstall: \(plan.app.name) (\(plan.app.bundleID))")
    }
}
