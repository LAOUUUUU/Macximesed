import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct GamesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "games",
        abstract: "Your games: how best to run each, and play with Boost and a heat graph.",
        discussion: """
            Finds games by their App Store category or Game Mode support, known games and launchers (Roblox, Steam, Minecraft launchers, GeForce NOW and others), Steam's library, Windows games in CrossOver bottles, and games you add. `macx games play NAME` turns Boost on, starts the game, records heat and load while you play, and turns Boost off when the game quits. Game Mode can't be switched on by another program: macOS does it when a supported game goes full screen.
            """,
        subcommands: [List.self, Play.self, Add.self, Forget.self],
        defaultSubcommand: List.self
    )

    static func find(_ name: String) throws -> GameEntry {
        let games = GameScanner.standard().scan()
        let n = name.lowercased()
        if let exact = games.first(where: { $0.name.lowercased() == n }) { return exact }
        let partial = games.filter { $0.name.lowercased().contains(n) }
        guard partial.count == 1, let only = partial.first else {
            if partial.isEmpty { throw UserError("No game called \(name). See: macx games   (add one: macx games add PATH)") }
            throw UserError("\(name) matches \(partial.map(\.name).joined(separator: ", ")). Be more specific.")
        }
        return only
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your games and how best to run each.")
        func run() throws {
            let games = GameScanner.standard().scan()
            guard !games.isEmpty else {
                print("No games found. Add one: macx games add /path/to/Game.app")
                return
            }
            for g in games {
                let kind: String
                switch g.kind {
                case .launcher: kind = "launcher"
                case .steam: kind = "Steam"
                case .windows(let b): kind = "CrossOver bottle \(b)"
                case .added: kind = "added by you"
                case .app: kind = "app"
                }
                print("\(g.name)  (\(kind)\(g.architectures.isEmpty ? "" : ", \(AppArch.kind(g.architectures))"))")
                print("  \(g.advice)")
            }
            print("\nPlay with Boost and a heat graph: macx games play NAME")
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a game macx didn't find.")
        @Argument(help: "Path to the game's .app.", completion: .file()) var path: String
        func run() throws {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
                throw UserError("\(path) isn't an app.")
            }
            var list = GameList.load()
            if !list.contains(url) { list.append(url) }
            try GameList.save(list)
            print("Added \(url.deletingPathExtension().lastPathComponent).")
        }
    }

    struct Forget: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a game you added (the game itself isn't touched).")
        @Argument(help: "Name or path.") var name: String
        func run() throws {
            let list = GameList.load()
            let keep = list.filter { !$0.path.lowercased().contains(name.lowercased()) }
            try GameList.save(keep)
            print(
                keep.count == list.count
                    ? "Nothing matched \(name)." : "Forgot \(list.count - keep.count) game\(list.count - keep.count == 1 ? "" : "s").")
        }
    }

    struct Play: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a game with Boost and record heat while you play.")
        @Argument(help: "Game name (from `macx games`).") var name: String
        @Flag(help: "Show Apple's Metal Performance HUD (FPS, GPU time) in the game.") var hud = false
        @Flag(help: "Don't turn Boost on; just record heat.") var noBoost = false

        nonisolated(unsafe) static var keep: [DispatchSourceSignal] = []
        static let signalQueue = DispatchQueue(label: "macx.games.signals")

        func run() throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            guard geteuid() != 0 else { throw UserError("Run it without sudo.") }
            let game = try GamesCommand.find(name)
            if case .windows = game.kind { throw UserError("Start Windows games from CrossOver. To watch heat meanwhile: macx top") }
            guard TweakLedger.load(at: Boost.defaultLedger) == nil else {
                throw UserError("Boost is already on. Turn it off first: macx boost off")
            }
            print("\(game.name): \(game.advice)")

            var boosted = false
            if !noBoost {
                let plan = try BoostCommand.plan(app: game.url.path)
                let ledger = try Boost.apply(plan, purpose: "game")
                boosted = true
                print(
                    "Boost on: \(ledger.changes.count) change\(ledger.changes.count == 1 ? "" : "s") (\(plan.demote.map(\.name).joined(separator: ", ").isEmpty ? "nothing busy to move aside" : "moved aside: " + plan.demote.map(\.name).joined(separator: ", ")))"
                )
            }
            func endBoost() {
                guard boosted, let l = TweakLedger.load(at: Boost.defaultLedger) else { return }
                let r = l.restore(system: RealSystem())
                print(
                    "Boost off: \(r.restored.count) changes put back\(r.failed.isEmpty ? "" : ", \(r.failed.count) couldn't be (macx boost off to retry)")."
                )
            }
            // Ctrl-C or a kill: put everything back before leaving.
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig, queue: Self.signalQueue)
                src.setEventHandler {
                    print("\nStopping.")
                    endBoost()
                    GameSessionGuard.clear()
                    Darwin.exit(130)
                }
                src.resume()
                Self.keep.append(src)
            }

            // Real paths on both sides: the kernel reports /private/tmp/..., a saved path may say /tmp/....
            let realApp = Self.realPath(game.url.path)
            let exeDir = realApp + "/Contents/MacOS/"
            var pid = Self.findPID(under: exeDir)
            if pid == nil {
                var args = ["/usr/bin/open"]
                if hud { args += ["--env", "MTL_HUD_ENABLED=1"] }
                if case .steam(let id) = game.kind, !hud { args += ["steam://rungameid/\(id)"] } else { args += ["-a", game.url.path] }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: args[0])
                p.arguments = Array(args.dropFirst())
                try p.run()
                p.waitUntilExit()
                for _ in 0..<60 where pid == nil {
                    Thread.sleep(forTimeInterval: 0.5)
                    pid = Self.findPID(under: exeDir)
                }
            } else {
                print("\(game.name) is already running; watching it.")
            }
            guard let gamePID = pid else {
                endBoost()
                throw UserError("\(game.name) didn't start within 30 s.")
            }
            GameSessionGuard.write(.init(pid: gamePID, game: game.name))
            if game.declaresGameMode { print("Tip: play full screen so macOS turns Game Mode on.") }
            print("Playing. Heat and load are recorded every 2 s; quit the game to see the graph.")

            var timeline = HeatTimeline()
            let started = Date()
            var before = CPUSampler.snapshot()
            var last = Date()
            while kill(gamePID, 0) == 0 {
                Thread.sleep(forTimeInterval: 2)
                let now = Date()
                let after = CPUSampler.snapshot()
                let game = CPUSampler.uses(before: before, after: after, interval: now.timeIntervalSince(last))
                    .filter { $0.path.hasPrefix(realApp + "/") }.reduce(0) { $0 + $1.cpuPercent }
                before = after
                last = now
                timeline.add(.init(time: now, level: .current, pressure: ThermalPressure.current(), cpuPercent: game))
            }
            endBoost()
            GameSessionGuard.clear()
            let session = GameSession(game: game.name, started: started, ended: Date(), timeline: timeline, boosted: boosted)
            print("\n" + session.summary())
            Self.save(session)
        }

        static func realPath(_ path: String) -> String {
            guard let r = realpath(path, nil) else { return path }
            defer { free(r) }
            return String(cString: r)
        }

        static func findPID(under dir: String) -> Int32? {
            ProcessTree.snapshot().first { $0.path.hasPrefix(dir) }.map { Int32($0.pid) }
        }

        static func save(_ s: GameSession) {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Macximesed/games")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmm"
            let file = dir.appendingPathComponent("\(f.string(from: s.started))-\(s.game.replacingOccurrences(of: "/", with: "-")).txt")
            if (try? (s.summary() + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil { print("Saved: \(file.path)") }
        }
    }
}
