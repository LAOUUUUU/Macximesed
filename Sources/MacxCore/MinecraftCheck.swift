import Foundation
import SQLite3

/// One Minecraft instance in Prism Launcher or the Modrinth App.
public struct MinecraftInstance: Sendable, Equatable {
    public enum Loader: String, Sendable, Equatable { case fabric, quilt, forge, neoforge }
    public var launcher: String
    public var name: String
    public var javaPath: String?
    public var memoryMB: Int?
    /// File names in the mods folder.
    public var mods: [String]
    public var loader: Loader?

    public init(launcher: String, name: String, javaPath: String?, memoryMB: Int?, mods: [String], loader: Loader?) {
        self.launcher = launcher
        self.name = name
        self.javaPath = javaPath
        self.memoryMB = memoryMB
        self.mods = mods
        self.loader = loader
    }
}

/// The read-only Minecraft check (research/performance-v3/RESEARCH.md): native Java, memory, and the standard
/// speed mods. It reads launcher settings and mods folders and never changes an instance.
public enum MinecraftCheck {
    public static var prismRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PrismLauncher")
    }
    public static var modrinthRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModrinthApp")
    }

    /// Every instance from both launchers, found where they keep them.
    public static func all() -> [MinecraftInstance] { prismInstances(root: prismRoot) + modrinthInstances(root: modrinthRoot) }

    static func ini(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix("[") else { continue }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
        }
        return out
    }

    static func modFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jar") }.sorted()
    }

    static func loader(fromPack url: URL) -> MinecraftInstance.Loader? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if text.contains("net.fabricmc.fabric-loader") { return .fabric }
        if text.contains("org.quiltmc.quilt-loader") { return .quilt }
        if text.contains("net.neoforged") { return .neoforge }
        if text.contains("net.minecraftforge") { return .forge }
        return nil
    }

    /// A loader guessed from the mods themselves (the Modrinth App keeps it in its database).
    static func loader(fromMods mods: [String]) -> MinecraftInstance.Loader? {
        // The most-named loader wins: packs carry a few jars built for both ("…-fabric-forge.jar").
        let m = mods.map { $0.lowercased() }
        let neo = m.filter { $0.contains("neoforge") }.count
        let counts: [(MinecraftInstance.Loader, Int)] = [
            (.fabric, m.filter { $0.contains("fabric") }.count), (.quilt, m.filter { $0.contains("quilt") }.count),
            (.neoforge, neo), (.forge, m.filter { $0.contains("forge") }.count - neo),
        ]
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    public static func prismInstances(root: URL) -> [MinecraftInstance] {
        let global = ini(root.appendingPathComponent("prismlauncher.cfg"))
        let dir = root.appendingPathComponent("instances")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { folder in
            let base = dir.appendingPathComponent(folder)
            let cfg = ini(base.appendingPathComponent("instance.cfg"))
            guard !cfg.isEmpty else { return nil }
            let memory = cfg["OverrideMemory"] == "true" ? cfg["MaxMemAlloc"] : global["MaxMemAlloc"]
            let java = cfg["OverrideJavaLocation"] == "true" || cfg["OverrideJava"] == "true" ? cfg["JavaPath"] : global["JavaPath"]
            let mods = modFiles(base.appendingPathComponent("minecraft/mods")) + modFiles(base.appendingPathComponent(".minecraft/mods"))
            return MinecraftInstance(
                launcher: "Prism", name: cfg["name"] ?? folder, javaPath: java, memoryMB: memory.flatMap { Int($0) }, mods: mods,
                loader: loader(fromPack: base.appendingPathComponent("mmc-pack.json")) ?? loader(fromMods: mods))
        }
    }

    /// The Modrinth App's memory setting (one for all instances), read from its database opened read-only.
    static func modrinthMemory(_ db: URL) -> Int? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "select mc_memory_max from settings limit 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : nil
    }

    public static func modrinthInstances(root: URL) -> [MinecraftInstance] {
        let dir = root.appendingPathComponent("profiles")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let memory = modrinthMemory(root.appendingPathComponent("app.db"))
        return names.sorted().compactMap { name in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            let mods = modFiles(dir.appendingPathComponent(name).appendingPathComponent("mods"))
            return MinecraftInstance(
                launcher: "Modrinth", name: name, javaPath: nil, memoryMB: memory, mods: mods, loader: loader(fromMods: mods))
        }
    }

    /// CPU types in a Mach-O file (thin or universal), as "arm64"/"x86_64". Reads only the header.
    public static func archs(of path: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 4096)) ?? Data()
        func u32(_ at: Int, big: Bool) -> UInt32? {
            guard data.count >= at + 4 else { return nil }
            let v = data[data.startIndex + at..<data.startIndex + at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return big ? v : v.byteSwapped
        }
        func name(_ cpu: UInt32) -> String? { cpu == 0x0100_000C ? "arm64" : cpu == 0x0100_0007 ? "x86_64" : nil }
        guard let magic = u32(0, big: true) else { return [] }
        switch magic {
        case 0xCFFA_EDFE:  // 64-bit, little-endian on disk
            return [u32(4, big: false).flatMap(name)].compactMap { $0 }
        case 0xCAFE_BABE:  // universal
            let n = Int(u32(4, big: true) ?? 0)
            return (0..<min(n, 8)).compactMap { u32(8 + $0 * 20, big: true).flatMap(name) }
        default: return []
        }
    }

    /// The speed mods, by what they do, with the names that count (Forge and Quilt ports included).
    /// `forge` is the mod to suggest on (old) Forge, where Sodium and Lithium have ports under other names.
    static let speedMods: [(what: String, mod: String, forge: String, names: [String])] = [
        ("rendering", "Sodium", "Embeddium", ["sodium", "embeddium", "rubidium"]),
        ("game logic", "Lithium", "Canary", ["lithium", "canary", "radium"]),
        ("memory", "FerriteCore", "FerriteCore", ["ferritecore"]),
    ]
    static func link(_ mod: String) -> String {
        "https://modrinth.com/mod/" + (mod == "FerriteCore" ? "ferrite-core" : mod.lowercased())
    }

    /// Plain-words advice for one instance; empty when it's already set up well.
    public static func advice(_ i: MinecraftInstance, physicalBytes: UInt64, javaArchs: [String]) -> [String] {
        var out: [String] = []
        if !javaArchs.isEmpty, !javaArchs.contains("arm64") {
            out.append(
                "Java runs through Rosetta (Intel). An Apple-silicon (arm64) Java is much faster: pick one in the launcher's Java settings."
            )
        }
        let ramGB = Int(physicalBytes >> 30)
        if let mb = i.memoryMB {
            let gb = Double(mb) / 1024
            let label = gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
            if mb > Int(physicalBytes >> 20) / 2 {
                out.append(
                    "\(label) of memory is over half of this Mac's \(ramGB) GB. More isn't faster (longer pauses) and leaves macOS short; 4 to 6 GB is usually right."
                )
            } else if (i.mods.count > 150 && mb < 6144) || (i.mods.count > 100 && mb < 4096) {
                let want = i.mods.count > 150 ? 6 : 4
                let whereSet =
                    i.launcher == "Modrinth"
                    ? " (the Modrinth App has one memory setting for every instance)" : " (Edit instance > Settings)"
                out.append("\(i.mods.count) mods with \(label) of memory: a pack this size usually wants \(want) GB\(whereSet).")
            }
        }
        if i.loader != nil {
            let lower = i.mods.map { $0.lowercased() }
            for m in speedMods where !m.names.contains(where: { n in lower.contains { $0.hasPrefix(n) || $0.contains("-\(n)") } }) {
                let mod = i.loader == .forge ? m.forge : m.mod
                out.append("No \(mod) (\(m.what)): \(link(mod))")
            }
        }
        return out
    }
}

/// Advice-only tips for games macx can't (and shouldn't) change.
public enum GameAdvice {
    public static func refreshNote(hz: Int) -> String {
        "Your screen shows up to \(hz) frames a second. macOS caps games there, so a frame-rate limit above \(hz) only adds heat."
    }

    /// Roblox: its own setting, never its files or memory (FPS unlockers and flag edits are how bans happen).
    public static func roblox(hz: Int) -> String {
        "Use Roblox's own Settings > Maximum Frame Rate, set to \(hz). FPS unlockers and ClientAppSettings edits gain nothing above \(hz) Hz, have to be redone after every update, and risk a ban."
    }

    public static var robloxInstalled: Bool {
        ["/Applications/Roblox.app", NSHomeDirectory() + "/Applications/Roblox.app"].contains { FileManager.default.fileExists(atPath: $0) }
    }
}
