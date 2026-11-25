import Foundation

/// How a game is best run on this Mac.
public enum GameRoute: String, Sendable, Equatable {
    case native, rosetta, crossover, cloud, unknown
}

public enum GameKind: Sendable, Equatable {
    case app, launcher, added
    case steam(appID: String)
    case windows(bottle: String)
}

public struct GameEntry: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var kind: GameKind
    public var bundleID: String?
    public var architectures: [AppArch]
    public var declaresGameMode: Bool
    public var route: GameRoute

    /// One line on how best to run it.
    public var advice: String {
        switch route {
        case .native:
            declaresGameMode
                ? "Runs natively. Supports Game Mode: play it full screen to turn Game Mode on."
                : "Runs natively on Apple silicon."
        case .rosetta:
            "Intel only: runs through Rosetta. Apple says macOS 27 is the last version that runs Intel apps (older games keep Rosetta), so look for an Apple-silicon version or play it on GeForce NOW."
        case .crossover: "Windows game through CrossOver (CrossOver 27 needs Apple silicon and macOS Sonoma or later)."
        case .cloud: "Cloud gaming: runs on NVIDIA's servers, so your Mac only streams it."
        case .unknown: "Couldn't read what it's built for."
        }
    }
}

/// `appmanifest_<id>.acf` in Steam's library (Valve's KeyValues text format).
public struct SteamManifest: Sendable, Equatable {
    public var appID: String
    public var name: String
    public var installDir: String

    public static func parse(_ text: String) -> SteamManifest? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true).map(String.init).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if parts.count >= 2 { values[parts[0].lowercased()] = parts[1] }
        }
        guard let id = values["appid"], let name = values["name"], let dir = values["installdir"] else { return nil }
        return SteamManifest(appID: id, name: name, installDir: dir)
    }
}

/// Finds games: apps that say they're games (App Store category or Game Mode key), known games and launchers
/// that don't, Steam's library, Windows games in CrossOver bottles, and anything the user added.
public struct GameScanner: Sendable {
    public var roots: [URL]
    public var steamApps: URL
    public var bottles: URL
    public var extra: [URL]
    public var hostIsARM: Bool

    public init(roots: [URL], steamApps: URL, bottles: URL, extra: [URL], hostIsARM: Bool = AppArch.hostIsARM) {
        self.roots = roots
        self.steamApps = steamApps
        self.bottles = bottles
        self.extra = extra
        self.hostIsARM = hostIsARM
    }

    public static func standard(extra: [URL] = GameList.load()) -> GameScanner {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GameScanner(
            roots: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
            steamApps: home.appendingPathComponent("Library/Application Support/Steam/steamapps"),
            bottles: home.appendingPathComponent("Library/Application Support/CrossOver/Bottles"), extra: extra)
    }

    /// Games that don't declare a games category.
    static let knownGames: Set<String> = ["com.roblox.RobloxPlayer", "com.mojang.minecraftlauncher"]
    static let launchers: Set<String> = [
        "com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "net.battle.app", "net.battle.bootstrapper", "com.gog.galaxy",
        "com.codeweavers.CrossOver", "com.nvidia.gfnpc.mall", "org.prismlauncher.PrismLauncher", "ModrinthApp",
        "com.mojang.minecraftlauncher",
    ]
    static let cloud: Set<String> = ["com.nvidia.gfnpc.mall"]

    public func scan() -> [GameEntry] {
        var out: [GameEntry] = []
        let fm = FileManager.default
        for root in roots {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasSuffix(".app") {
                if let e = entry(root.appendingPathComponent(name), requireGame: true) { out.append(e) }
            }
        }
        out += steamGames()
        out += windowsGames()
        for url in extra where !out.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            if var e = entry(url, requireGame: false) {
                e.kind = .added
                out.append(e)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func info(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    func entry(_ app: URL, requireGame: Bool) -> GameEntry? {
        guard let info = info(app) else { return nil }
        let id = info["CFBundleIdentifier"] as? String
        let category = (info["LSApplicationCategoryType"] as? String ?? "").lowercased()
        let gameMode = (info["GCSupportsGameMode"] as? Bool ?? false) || (info["LSSupportsGameMode"] as? Bool ?? false)
        let isLauncher = id.map(Self.launchers.contains) ?? false
        let isGame = category.contains("games") || gameMode || isLauncher || (id.map(Self.knownGames.contains) ?? false)
        guard isGame || !requireGame else { return nil }
        let exe = (info["CFBundleExecutable"] as? String).map { app.appendingPathComponent("Contents/MacOS/\($0)") }
        let archs = exe.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.map(MachO.architectures) ?? []
        let route: GameRoute =
            id.map(Self.cloud.contains) == true
            ? .cloud : archs.isEmpty ? .unknown : (hostIsARM && !archs.contains(.arm64)) ? .rosetta : .native
        return GameEntry(
            name: (app.lastPathComponent as NSString).deletingPathExtension, url: app, kind: isLauncher ? .launcher : .app, bundleID: id,
            architectures: archs, declaresGameMode: gameMode, route: route)
    }

    func steamGames() -> [GameEntry] {
        let fm = FileManager.default
        var out: [GameEntry] = []
        for name in (try? fm.contentsOfDirectory(atPath: steamApps.path)) ?? []
        where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            guard let text = try? String(contentsOf: steamApps.appendingPathComponent(name), encoding: .utf8),
                let m = SteamManifest.parse(text)
            else { continue }
            let dir = steamApps.appendingPathComponent("common/\(m.installDir)")
            let app = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).first { $0.hasSuffix(".app") }.map {
                dir.appendingPathComponent($0)
            }
            guard let app, var e = entry(app, requireGame: false) else { continue }
            e.name = m.name
            e.kind = .steam(appID: m.appID)
            out.append(e)
        }
        return out
    }

    /// `.exe` files under each bottle's Program Files, two folders deep, minus installers and Windows itself.
    func windowsGames() -> [GameEntry] {
        let fm = FileManager.default
        let skip = ["unins", "uninst", "setup", "crash", "redist", "vc_redist", "dxsetup", "update"]
        var out: [GameEntry] = []
        for bottle in (try? fm.contentsOfDirectory(atPath: bottles.path)) ?? [] where !bottle.hasPrefix(".") {
            let drive = bottles.appendingPathComponent("\(bottle)/drive_c")
            for pf in ["Program Files", "Program Files (x86)"] {
                let base = drive.appendingPathComponent(pf)
                for game in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                    let dir = base.appendingPathComponent(game)
                    for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.lowercased().hasSuffix(".exe") {
                        let n = (f as NSString).deletingPathExtension
                        guard !skip.contains(where: { n.lowercased().hasPrefix($0) }) else { continue }
                        out.append(
                            GameEntry(
                                name: n, url: dir.appendingPathComponent(f), kind: .windows(bottle: bottle), bundleID: nil,
                                architectures: [],
                                declaresGameMode: false, route: .crossover))
                    }
                }
            }
        }
        return out
    }
}

/// Games the user added by hand (`macx games add PATH`).
public enum GameList {
    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/games.json")
    }

    public static func load(from file: URL = file) -> [URL] {
        guard let data = try? Data(contentsOf: file), let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    public static func save(_ urls: [URL], to file: URL = file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(urls.map(\.path)).write(to: file, options: .atomic)
    }
}

/// One play session: how long, how hot, how busy. Saved to ~/Library/Logs/Macximesed/games/.
public struct GameSession: Sendable {
    public var game: String
    public var started: Date
    public var ended: Date
    public var timeline: HeatTimeline
    public var boosted: Bool

    public init(game: String, started: Date, ended: Date, timeline: HeatTimeline, boosted: Bool) {
        self.game = game
        self.started = started
        self.ended = ended
        self.timeline = timeline
        self.boosted = boosted
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m < 1 ? "\(Int(s)) s" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    public func summary(width: Int = 60) -> String {
        let peak = timeline.peak.map { $0.rawValue.capitalized } ?? "unknown"
        let throttled = timeline.secondsThrottled
        return """
            \(game): \(Self.duration(ended.timeIntervalSince(started)))\(boosted ? ", with Boost" : "")
            Heat  \(timeline.levelStrip(width: width))
            Load  \(timeline.loadStrip(width: width))
            Peak: \(peak) · \(throttled > 0 ? "throttling for \(Int(throttled)) s" : "no throttling")
            """
    }
}

/// If macx stops while a game runs, the next macx run sees the game is gone and turns Boost off.
public enum GameSessionGuard {
    public static var file: URL { file(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// The background watch (root) reads the signed-in user's file.
    public static func file(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Macximesed/game-session.json")
    }

    public struct Record: Codable, Sendable {
        public var pid: Int32
        public var game: String
        public init(pid: Int32, game: String) {
            self.pid = pid
            self.game = game
        }
    }

    public static func needsRestore(gamePID: Int32, isAlive: (Int32) -> Bool) -> Bool { !isAlive(gamePID) }

    public static func write(_ r: Record) { try? JSONEncoder().encode(r).write(to: file, options: .atomic) }
    public static func clear() { try? FileManager.default.removeItem(at: file) }
    public static func load(from f: URL = file) -> Record? {
        (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    /// Called at macx start-up: a game session whose game has quit leaves Boost on; undo it.
    public static func recoverIfNeeded(system: SystemControl = RealSystem()) -> Bool {
        guard let r = load(), needsRestore(gamePID: r.pid, isAlive: { kill($0, 0) == 0 }) else { return false }
        if let ledger = TweakLedger.load(at: Boost.defaultLedger), ledger.purpose == "game" { _ = ledger.restore(system: system) }
        RawMouse.restore()
        clear()
        return true
    }
}
