import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch live for stealer behaviour (needs sudo and Full Disk Access for macx).",
        discussion: """
            Runs Apple's eslogger and checks every program start, launch-item write, quarantine removal and new
            background item as it happens: pasted download-and-run or hidden base64 commands, fake password
            prompts, dscl password checks, fake com.apple launch items and folders, unsigned programs starting from
            hidden or temporary folders. Alerts print here and are saved to ~/Library/Logs/Macximesed/watch.jsonl.

            It can't block anything before it runs (that needs Apple's restricted Endpoint Security entitlement),
            but --suspend freezes the process behind a critical alert straight away so you can decide.

            Run it as:  sudo macx watch
            eslogger needs Full Disk Access for the app responsible for it. The installed macx (scripts/install.sh)
            is its own responsible app, so grant it to ~/.local/bin/macx (macx privacy --open).
            """
    )

    @Flag(help: "Freeze (SIGSTOP) the process behind each critical alert.")
    var suspend = false

    @Option(help: "Lowest severity to show: info, low, medium, high, critical.")
    var minSeverity: String = "medium"

    @Option(help: "Check a saved eslogger JSON Lines file instead of watching live (no sudo needed).", completion: .file())
    var replay: String?

    @Option(help: "Write alerts to this JSON Lines file instead of ~/Library/Logs/Macximesed/watch.jsonl.", completion: .file())
    var log: String?

    func run() throws {
        // Line-buffer stdout so alerts reach a log file or pipe straight away, not when macx exits.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let minimum = Severity.allCases.first(where: { String(describing: $0) == minSeverity.lowercased() }) else {
            throw UserError("Unknown severity \"\(minSeverity)\". Use info, low, medium, high or critical.")
        }
        let user = Self.invokingUser()
        let rules = WatchRules(home: user.home)
        let log = AlertLog(
            home: user.home, uid: user.uid, gid: user.gid,
            file: self.log.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })

        if let replay {
            guard let text = try? String(contentsOfFile: (replay as NSString).expandingTildeInPath, encoding: .utf8) else {
                throw UserError("Can't read \(replay).")
            }
            var count = 0
            var events = 0
            for line in text.split(separator: "\n") {
                guard let e = ESEvent.parse(String(line)) else { continue }
                events += 1
                for a in rules.evaluate(e) where a.severity >= minimum {
                    Self.printAlert(a)
                    count += 1
                }
            }
            print("\nReplayed \(events) events: \(count) alerts.")
            return
        }

        guard geteuid() == 0 else {
            throw UserError("Live watching needs root. Run: sudo \(Responsibility.executablePath ?? "macx") watch")
        }

        let es = Process()
        es.executableURL = URL(fileURLWithPath: "/usr/bin/eslogger")
        es.arguments = WatchRules.events
        let out = Pipe()
        let err = Pipe()
        es.standardOutput = out
        es.standardError = err
        try es.run()

        // Stop eslogger with us on Ctrl-C or a kill.
        let child = es.processIdentifier
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                kill(child, SIGTERM)
                print("\nStopped watching.")
                Darwin.exit(0)
            }
            src.resume()
            Self.keep.append(src)
        }

        print("Watching (\(WatchRules.events.joined(separator: ", "))). Showing \(minSeverity) and above. Ctrl-C stops.")
        if suspend { print("Critical alerts freeze the process behind them.") }
        print("Alerts are also saved to \(log.file.path)\n")

        let handle = out.fileHandleForReading
        var buffer = Data()
        let started = Date()
        var seen = 0
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // eslogger exited
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let e = ESEvent.parse(line) else { continue }
                seen += 1
                for a in rules.evaluate(e) {
                    log.append(a)
                    guard a.severity >= minimum else { continue }
                    Self.printAlert(a)
                    // Critical: stop it first (if asked), then keep the evidence while the process is still there.
                    if a.severity == .critical {
                        var frozen: [Int] = []
                        if suspend {
                            frozen = Self.freeze(a)
                            if !frozen.isEmpty { log.appendFreeze(alertRule: a.rule, pids: frozen) }
                        }
                        let recent =
                            (try? String(contentsOf: log.file, encoding: .utf8))?.split(separator: "\n").suffix(50).map(String.init) ?? []
                        if let c = IncidentCapture.fromAlert(
                            a, frozen: frozen, home: user.home, uid: user.uid, gid: user.gid, timeline: recent)
                        {
                            print("           Evidence kept: macx incident show \(c.id)")
                        }
                    }
                }
            }
        }
        es.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if seen == 0, Date().timeIntervalSince(started) < 10 {
            var hint = "eslogger stopped: \(message.isEmpty ? "exit \(es.terminationStatus)" : message)"
            if message.lowercased().contains("not permitted") || message.contains("TCC") || message.contains("Full Disk") {
                hint += "\nGive Full Disk Access to "
                hint += Responsibility.isOwnResponsibleProcess ? (Responsibility.executablePath ?? "macx") : "your terminal app"
                hint += " (macx privacy --open), then try again."
            }
            throw UserError(hint)
        }
        print("eslogger stopped (\(es.terminationStatus)).")
    }

    nonisolated(unsafe) static var keep: [DispatchSourceSignal] = []

    static func printAlert(_ a: WatchAlert) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(time)] \(a.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(a.title)  [\(a.rule)]")
        if let p = a.processPath { print("           by \(p)\(a.pid.map { " (pid \($0))" } ?? "")") }
        if let d = a.detail { d.split(separator: "\n").forEach { print("           \($0)") } }
    }

    /// Stops the process and everything it started, top-down, and shows who started it.
    @discardableResult
    static func freeze(_ a: WatchAlert) -> [Int] {
        guard let pid = a.pid, pid > 1, pid != Int(getpid()) else { return [] }
        let before = ProcessTree.snapshot()
        let chain = ProcessTree.ancestry(of: pid, in: before).dropFirst().prefix(6)
        let frozen = ProcessTree.freeze(root: pid)
        guard !frozen.isEmpty else { return [] }
        let list = frozen.map(String.init).joined(separator: " ")
        print("           Froze \(frozen.count) process\(frozen.count == 1 ? "" : "es"): \(list)")
        if !chain.isEmpty {
            print(
                "           Started by: " + chain.map { "\(($0.path as NSString).lastPathComponent) (\($0.pid))" }.joined(separator: " ← "))
        }
        print("           Resume: sudo kill -CONT \(list)    End them: sudo kill -KILL \(list)")
        return frozen
    }

    /// The real user behind sudo, so ~/ paths and the log file are theirs, not root's.
    static func invokingUser() -> (home: URL, uid: uid_t, gid: gid_t) {
        if let name = ProcessInfo.processInfo.environment["SUDO_USER"], let pw = getpwnam(name), let dir = pw.pointee.pw_dir {
            return (URL(fileURLWithPath: String(cString: dir)), pw.pointee.pw_uid, pw.pointee.pw_gid)
        }
        return (FileManager.default.homeDirectoryForCurrentUser, getuid(), getgid())
    }
}

/// Alerts as JSON Lines in the user's Logs folder, owned by the user even when macx runs as root.
struct AlertLog {
    /// Millisecond timestamps, so delays can be measured.
    nonisolated(unsafe) static let timeFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    let file: URL
    let uid: uid_t
    let gid: gid_t

    init(home: URL, uid: uid_t, gid: gid_t, file: URL? = nil) {
        self.file = file ?? home.appendingPathComponent("Library/Logs/Macximesed/watch.jsonl")
        self.uid = uid
        self.gid = gid
    }

    /// Records when a freeze happened and what it stopped (used to measure alert-to-stop time).
    func appendFreeze(alertRule: String, pids: [Int]) {
        write([
            "time": Self.timeFormat.string(from: Date()), "epoch": Date().timeIntervalSince1970,
            "rule": "frozen", "severity": "info", "title": "Froze after \(alertRule)", "detail": "", "pid": pids.first ?? -1,
            "process": "", "frozen": pids,
        ])
    }

    func append(_ a: WatchAlert) {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            chown(dir.path, uid, gid)
        }
        let record: [String: Any] = [
            "time": Self.timeFormat.string(from: Date()), "epoch": Date().timeIntervalSince1970,
            "rule": a.rule, "severity": String(describing: a.severity),
            "title": a.title, "detail": a.detail ?? "", "pid": a.pid ?? -1, "process": a.processPath ?? "",
        ]
        write(record)
    }

    func write(_ record: [String: Any]) {
        let fm = FileManager.default
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
            chown(file.path, uid, gid)
        }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        }
    }
}
