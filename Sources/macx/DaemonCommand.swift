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
        subcommands: [Install.self, Uninstall.self, Status.self, Restart.self],
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

        func run() throws {
            try requireRoot("install")
            guard let exe = Responsibility.executablePath.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) else {
                throw UserError("Can't find macx's own path.")
            }
            guard let user = WatchUser.resolve() else {
                throw UserError("Run it with sudo from your own account (sudo macx daemon install), so alerts reach you.")
            }
            let plan: DaemonPlan
            do {
                plan = try DaemonPlan(executable: exe, user: user, suspend: suspend)
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
            Thread.sleep(forTimeInterval: 4)
            Status.show()
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
            print("  Log: \(DaemonPlan.logPath.path)    Alerts: macx alerts")
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
