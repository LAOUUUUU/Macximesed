import Foundation

/// How much can go wrong. Higher tiers ask more before acting.
public enum Tier: String, CaseIterable, Sendable, Codable {
    case safe, medium, risky, extreme
}

/// Who a cleanup item belongs to. Decided only from facts (bundle IDs on disk, tools' own answers),
/// never from how a name looks.
public enum Ownership: Sendable, Equatable {
    case app(name: String, bundleID: String)
    case tool(String)
    case system
    case unknown

    public var label: String {
        switch self {
        case .app(let name, _): name
        case .tool(let tool): tool
        case .system: "macOS"
        case .unknown: "unknown owner"
        }
    }
}

public struct CleanupItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var tier: Tier
    public var paths: [URL]
    public var bytes: UInt64
    public var owner: Ownership
    /// Why moving it now could upset something: a process with files open inside, or its app running.
    public var inUseBy: String?
}

public enum CleanupCatalog {
    /// Things that are rebuilt automatically when needed. Apple's caches (`com.apple.*`, or owned by
    /// an Apple bundle), `~/.cache` and Macximesed's own data are never included.
    public static func safe(_ ctx: SystemContext) -> [CleanupItem] {
        var items: [CleanupItem] = []
        let toolByPath = Dictionary(ctx.toolCaches.map { ($0.url.standardizedFileURL.path, $0.tool) }, uniquingKeysWith: { a, _ in a })

        func inUse(_ paths: [URL], owner: Ownership) -> String? {
            if case .app(let name, let id) = owner, ctx.runningBundleIDs.contains(id) { return name }
            for p in paths {
                if let f = OpenFiles.holder(of: p, in: ctx.openFiles) { return "\(f.process) (pid \(f.pid))" }
            }
            return nil
        }

        func add(_ id: String, _ title: String, _ paths: [URL], owner: Ownership) {
            let bytes = paths.reduce(0) { $0 + allocatedSize(of: $1) }
            guard !paths.isEmpty, bytes > 0 else { return }
            items.append(
                CleanupItem(
                    id: id, title: title, tier: .safe, paths: paths, bytes: bytes,
                    owner: owner, inUseBy: inUse(paths, owner: owner)))
        }

        let caches = ctx.library.appendingPathComponent("Caches", isDirectory: true)
        for url in children(of: caches) {
            let name = url.lastPathComponent
            if name == "Macximesed" || name.hasPrefix(".") { continue }
            let owner = ownership(of: url, ctx: ctx, toolByPath: toolByPath)
            if owner == .system { continue }
            add("cache:\(name)", "\(name) cache", [url], owner: owner)
        }

        add("logs:user", "Your app logs and crash reports", children(of: ctx.library.appendingPathComponent("Logs")), owner: .system)
        let derived = ctx.derivedData ?? ctx.library.appendingPathComponent("Developer/Xcode/DerivedData")
        add("xcode:derived-data", "Xcode build data (DerivedData)", children(of: derived), owner: .tool("Xcode"))
        add(
            "xcode:device-support", "Xcode iOS device support files",
            children(of: ctx.library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport")), owner: .tool("Xcode"))
        add(
            "simulator:caches", "Simulator caches",
            children(of: ctx.library.appendingPathComponent("Developer/CoreSimulator/Caches")), owner: .tool("Xcode"))

        // Tool caches outside ~/Library/Caches (npm, pnpm...). Ones inside it were handled above.
        for tc in ctx.toolCaches where !tc.url.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path + "/") {
            add(
                "\(tc.tool):cache", "\(tc.tool) download cache", FileManager.default.fileExists(atPath: tc.url.path) ? [tc.url] : [],
                owner: .tool(tc.tool))
        }
        return items
    }

    /// `only` empty means every item with a known owner. Naming items in `only` is an explicit choice,
    /// so unknown owners are allowed then. Items in use are left out unless asked for.
    public static func select(_ items: [CleanupItem], only: Set<String>, includeInUse: Bool, includeUnknown: Bool) -> [CleanupItem] {
        items.filter { item in
            let wanted = only.isEmpty ? (item.owner != .unknown || includeUnknown) : only.contains(item.id)
            return wanted && (item.inUseBy == nil || includeInUse)
        }
    }

    /// Moves the items into the undo store. Nothing is deleted.
    public static func run(_ items: [CleanupItem], store: UndoStore) throws -> UndoBatch {
        try store.stash(items.flatMap(\.paths), reason: "clean: \(items.map(\.id).joined(separator: ", "))")
    }

    // MARK: - Helpers

    static func ownership(of url: URL, ctx: SystemContext, toolByPath: [String: String]) -> Ownership {
        if let tool = toolByPath[url.standardizedFileURL.path] { return .tool(tool) }
        let name = url.lastPathComponent
        if name.hasPrefix("com.apple.") { return .system }
        if let owner = ctx.bundles.owner(of: name) {
            return owner.bundleID.hasPrefix("com.apple.") ? .system : .app(name: owner.name, bundleID: owner.bundleID)
        }
        return .unknown
    }

    static func children(of dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0 != ".DS_Store" }.sorted().map { dir.appendingPathComponent($0) }
    }
}
