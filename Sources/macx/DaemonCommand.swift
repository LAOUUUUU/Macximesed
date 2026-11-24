import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the live watch in the background, without a terminal (a launchd daemon).",
        discussion: """
            `sudo macx daemon install` sets up /Library/LaunchDaemons/\(DaemonPlan.label).plist, which runs Macximesed.app's own macx as `macx watch` from startup on. High and critical alerts show as notifications, and every alert is saved to ~/Library/Logs/Macximesed/watch.jsonl (see `macx alerts`). It needs Full Disk Access for Macximesed.app (macx privacy --open).
            """,
        subcommands: [
            Install.self, Uninstall.self, Status.self, Restart.self, Pause.self, Resume.self, Downloads.self, LogLevelCommand.self,
        ],
        defaultSubcommand: Status.self
    )

    static let target = "system/\(DaemonPlan.label)"

    static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    static var isLoaded: Bool { launchctl(["print", target]).status == 0 }

    /// `bootout` returns before launchd has finished unloading, and bootstrapping again too soon fails with
    /// error 5 (Input/output error). So wait for it to be gone, then load with a few retries.
    static func unload() {
        guard isLoaded else { return }
        _ = launchctl(["bootout", target])
        for _ in 0..<50 where isLoaded { Thread.sleep(forTimeInterval: 0.2) }
        try? DaemonStatus(state: .stopped, message: "Stopped by macx daemon.").write()
    }

    static func load() throws {
        var last = (status: Int32(0), output: "")
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            last = launchctl(["bootstrap", "system", DaemonPlan.plistPath.path])
            if last.status == 0 || isLoaded { return }
        }
        throw UserError("launchctl bootstrap failed (\(last.status)): \(last.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    static func requireRoot(_ verb: String) throws {
        guard geteuid() == 0 else { throw UserError("This needs root. Run: sudo macx daemon \(verb)") }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install and start the background watch.")
        @Flag(help: "Freeze (SIGSTOP) the process behind each critical alert.") var suspend = false
        @Flag(help: "Don't check finished downloads in ~/Downloads.") var noDownloads = false
        @Option(help: "How much it writes to its log: trace, debug, info, warning or error.") var logLevel: String = "info"

        func run() throws {
            try requireRoot("install")
            guard let exe = Responsibility.executablePath.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) else {
                throw UserError("Can't find macx's own path.")
            }
            guard let user = WatchUser.resolve() else {
                throw UserError("Run it with sudo from your own account (sudo macx daemon install), so alerts reach you.")
            }
            guard let level = LogLevel(name: logLevel) else {
                throw UserError("\"\(logLevel)\" isn't a level. Use trace, debug, info, warning or error.")
            }
            let plan: DaemonPlan
            do {
                plan = try DaemonPlan(executable: exe, user: user, suspend: suspend, downloads: !noDownloads, logLevel: level)
            } catch {
                throw UserError(
                    "macx must run from Macximesed.app (Full Disk Access belongs to the app). Install it with scripts/install.sh, then run:\n  sudo ~/.local/bin/macx daemon install"
                )
            }
            let fm = FileManager.default
            try fm.createDirectory(at: DaemonPlan.logDir, withIntermediateDirectories: true)
            chmod(DaemonPlan.logDir.path, 0o755)
            unload()
            try plan.plistData().write(to: plan.plistPath, options: .atomic)
            chown(plan.plistPath.path, 0, 0)
            chmod(plan.plistPath.path, 0o644)
            try load()
            Log.info("daemon", "installed: \(plan.arguments.joined(separator: " ")) for \(user.name)")
            print("Installed \(plan.plistPath.path)")
            print("Runs: \(exe.path) \(plan.arguments.joined(separator: " ")) for \(user.name)")
            print("Checking it started...")
            Thread.sleep(forTimeInterval: 4)
            Status.show()
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the background watch and remove it.")
        func run() throws {
            try requireRoot("uninstall")
            unload()
            if FileManager.default.fileExists(atPath: DaemonPlan.plistPath.path) {
                try FileManager.default.removeItem(at: DaemonPlan.plistPath)
            }
            try? DaemonStatus(state: .stopped, message: "Uninstalled.").write()
            Log.info("daemon", "uninstalled")
            print("Background watch removed. Alerts already saved stay in ~/Library/Logs/Macximesed/watch.jsonl.")
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart it (after giving Full Disk Access, for example).")
        func run() throws {
            try requireRoot("restart")
            guard FileManager.default.fileExists(atPath: DaemonPlan.plistPath.path) else {
                throw UserError("Not installed. Run: sudo macx daemon install")
            }
            unload()
            try load()
            Log.info("daemon", "restarted")
            Thread.sleep(forTimeInterval: 4)
            Status.show()
        }
    }

    struct Pause: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop notifications and freezing for a while; alerts are still logged. It turns itself back on.",
            discussion: "Needs root, so nothing running as you can pause it. At most 24h. Resume early with `sudo macx daemon resume`."
        )
        @Option(name: .customLong("for"), help: "How long: 1h, 30m, or minutes (at most 24h).") var duration: String = "1h"

        func run() throws {
            try requireRoot("pause")
            guard let seconds = WatchPause.parseDuration(duration) else {
                throw UserError("\"\(duration)\" isn't a duration from 1 minute to 24 hours (try 1h or 30m).")
            }
            guard FileManager.default.fileExists(atPath: DaemonPlan.plistPath.path) else {
                throw UserError("The background watch isn't installed (sudo macx daemon install).")
            }
            let until = Date().addingTimeInterval(seconds)
            try WatchPause.write(until: until)
            chown(WatchPause.file.path, 0, 0)
            Log.info("daemon", "paused for \(Int(seconds / 60)) min")
            print("Paused until \(WatchState.clock(until)). Alerts are still logged; notifications and freezing are off.")
            print("Resume early: sudo macx daemon resume")
        }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "End a pause now.")
        func run() throws {
            try requireRoot("resume")
            WatchPause.clear()
            Log.info("daemon", "resumed")
            print("Resumed: notifications and freezing are back on.")
        }
    }

    /// The installed plist and what it says. Reading needs no root: the file is root-owned but readable.
    static func installedPlist() throws -> (plist: [String: Any], settings: DaemonSettings) {
        let path = DaemonPlan.plistPath
        guard let data = try? Data(contentsOf: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UserError("The background watch isn't installed (sudo macx daemon install).") }
        guard let settings = DaemonSettings(plist: plist) else {
            throw UserError("\(path.path) isn't the plist macx writes. Reinstall it: sudo macx daemon install")
        }
        return (plist, settings)
    }

    /// Writes a changed plist (root-owned, 0644) and restarts the watch with it. Written before the watch is
    /// stopped: if the write fails, the running watch is left as it was.
    static func rewrite(_ plist: [String: Any]?) throws {
        let path = DaemonPlan.plistPath
        guard let plist else { throw UserError("Couldn't change \(path.path).") }
        let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try out.write(to: path, options: .atomic)
        chown(path.path, 0, 0)
        chmod(path.path, 0o644)
        unload()
        try load()
    }

    struct Downloads: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show, or turn on or off, the check of finished downloads in ~/Downloads.",
            discussion: """
                `macx daemon downloads` shows the setting (no sudo). `sudo macx daemon downloads on|off` changes it in the root-owned launchd plist and restarts the watch. Only root can change it, so nothing running as you can switch it off.
                """
        )
        enum Setting: String, ExpressibleByArgument, CaseIterable { case on, off }
        @Argument(help: "on or off. Leave it out to see the current setting.") var setting: Setting?

        func run() throws {
            let (plist, current) = try installedPlist()
            guard let setting else {
                print("Downloads watch: \(current.downloads ? "on" : "off (turn it on: sudo macx daemon downloads on)")")
                return
            }
            try requireRoot("downloads \(setting.rawValue)")
            let on = setting == .on
            guard on != current.downloads else {
                print("The Downloads watch is already \(setting.rawValue).")
                return
            }
            try rewrite(DaemonSettings.plist(plist, downloads: on))
            Log.info("daemon", "Downloads watch turned \(setting.rawValue)")
            print("Downloads watch: \(setting.rawValue). The background watch restarted with it.")
            Thread.sleep(forTimeInterval: 4)
            Status.show()
        }
    }

    /// `macx daemon log [level]`. Named apart from MacxCore's `Log`, which it would otherwise hide in here.
    struct LogLevelCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "log",
            abstract: "Show or change how much the background watch writes to its log.",
            discussion: """
                The background watch writes to \(LogFile.rootFolder.path)/watch.log. `macx daemon log` shows the level (no sudo). `sudo macx daemon log debug` (or trace) adds detail while you look into a problem; `sudo macx daemon log info` puts it back. It's kept in the root-owned launchd plist, and changing it restarts the watch.
                """
        )
        @Argument(help: "trace, debug, info, warning or error. Leave it out to see the current level.") var level: String?

        func run() throws {
            let (plist, current) = try installedPlist()
            guard let level else {
                print("Background watch log: \(current.logLevel.name), in \(LogFile.rootFolder.path)/watch.log")
                return
            }
            guard let wanted = LogLevel(name: level) else {
                throw UserError("\"\(level)\" isn't a level. Use trace, debug, info, warning or error.")
            }
            try requireRoot("log \(wanted.name)")
            guard wanted != current.logLevel else {
                print("The background watch already logs at \(wanted.name).")
                return
            }
            try rewrite(DaemonSettings.plist(plist, logLevel: wanted))
            Log.info("daemon", "log level set to \(wanted.name)")
            print("Background watch log: \(wanted.name). The watch restarted with it.")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Is the background watch running, and what did it last say?")
        func run() throws { Status.show() }

        static func show() {
            let installed = FileManager.default.fileExists(atPath: DaemonPlan.plistPath.path)
            let info = launchctl(["print", target])
            guard installed || info.status == 0 else {
                print("Background watch: not installed (sudo macx daemon install).")
                return
            }
            let pid = info.output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
            let state = info.output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("state = ") }
            print("Background watch: \(info.status == 0 ? "loaded" : "installed but not loaded")")
            if let state { print("  launchd \(state.trimmingCharacters(in: .whitespaces))") }
            if let pid { print("  \(pid.trimmingCharacters(in: .whitespaces))") }
            if let s = DaemonStatus.read() {
                let when = DateFormatter.localizedString(from: s.since, dateStyle: .short, timeStyle: .medium)
                let stale = info.status != 0 && s.state == .watching
                print("  macx \(stale ? "last said" : "says") (\(when)): \(s.state.rawValue). \(s.message)")
                if info.status != 0 { print("  Start it: sudo macx daemon restart") }
            }
            if let until = WatchPause.activeUntil() { print("  Paused until \(WatchState.clock(until)) (sudo macx daemon resume)") }
            if let settings = DaemonSettings.read() {
                let (now, other) = settings.downloads ? ("on", "off") : ("off", "on")
                print("  Downloads watch: \(now) (sudo macx daemon downloads \(other))")
                print("  Its log: \(LogFile.rootFolder.path)/watch.log, level \(settings.logLevel.name) (sudo macx daemon log debug)")
            }
            if let user = WatchUser.resolve() ?? WatchUser.lookup(NSUserName()) {
                print(
                    "  Notifications: \(AppPresence.isAppRunning(userUID: user.uid) ? "shown by the Macximesed app (open)" : "shown through osascript (the app isn't open)")"
                )
            }
            print("  Output: \(DaemonPlan.logPath.path)    Alerts: macx alerts")
        }
    }
}

struct Alerts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent alerts from the live and background watch.")
    @Option(name: .short, help: "How many to show.") var n: Int = 20
    @Option(help: "Lowest severity to show: info, low, medium, high, critical.") var minSeverity: String = "low"
    @Flag(help: "Keep showing new alerts as they arrive.") var follow = false

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let minimum = Severity.allCases.first(where: { String(describing: $0) == minSeverity.lowercased() }) else {
            throw UserError("Unknown severity \"\(minSeverity)\".")
        }
        let home = WatchUser.resolve()?.home ?? FileManager.default.homeDirectoryForCurrentUser
        let file = home.appendingPathComponent("Library/Logs/Macximesed/watch.jsonl")
        var printed = 0
        func show(_ text: String, limit: Int?) {
            var records = AlertRecord.parse(text).filter { $0.severity >= minimum && $0.rule != "frozen" }
            if let limit { records = Array(records.suffix(limit)) }
            for r in records {
                let when = DateFormatter.localizedString(from: r.time, dateStyle: .short, timeStyle: .medium)
                print("[\(when)] \(r.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(r.title)  [\(r.rule)]")
                if !r.process.isEmpty { print("           by \(r.process)") }
                if r.isSystemProgram { print("           (\(WatchAlert.systemProgramNote))") }
                for line in r.detail.split(separator: "\n").prefix(4) { print("           \(line)") }
            }
            printed += records.count
        }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        show(text, limit: n)
        if printed == 0 { print("No alerts\(minimum > .info ? " at \(minSeverity) or above" : "") in \(file.path).") }
        guard follow else { return }
        var offset = text.utf8.count
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard let h = try? FileHandle(forReadingFrom: file) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            if size < offset { offset = 0 }
            if size > offset {
                try? h.seek(toOffset: UInt64(offset))
                let data = h.readDataToEndOfFile()
                offset += data.count
                show(String(decoding: data, as: UTF8.self), limit: nil)
            }
            try? h.close()
        }
    }
}
