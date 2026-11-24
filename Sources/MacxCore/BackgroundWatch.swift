import Darwin
import Foundation

/// The person `macx watch` works for: their home holds the log, the hash feed and the cases, and alerts go to
/// their screen. Under sudo that's SUDO_USER; in the launchd daemon it's MACX_USER, set at install time.
public struct WatchUser: Sendable, Equatable {
    public var name: String
    public var uid: uid_t
    public var gid: gid_t
    public var home: URL

    public init(name: String, uid: uid_t, gid: gid_t, home: URL) {
        self.name = name
        self.uid = uid
        self.gid = gid
        self.home = home
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment, lookup: (String) -> WatchUser? = WatchUser.lookup
    ) -> WatchUser? {
        for key in ["SUDO_USER", "MACX_USER"] {
            if let name = environment[key], !name.isEmpty { return lookup(name) }
        }
        return nil
    }

    public static func lookup(_ name: String) -> WatchUser? {
        guard let pw = getpwnam(name), let dir = pw.pointee.pw_dir else { return nil }
        return WatchUser(name: name, uid: pw.pointee.pw_uid, gid: pw.pointee.pw_gid, home: URL(fileURLWithPath: String(cString: dir)))
    }
}

/// The launchd daemon that runs `macx watch` without a terminal. It runs the binary inside Macximesed.app:
/// a launchd job is its own responsible process, so the Full Disk Access check is about Macximesed.app,
/// not about Terminal or sudo.
public struct DaemonPlan {
    public enum Problem: Error, Equatable { case notInApp }

    public static let label = "dev.macximesed.watch"
    public static let plistPath = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    public static let logDir = URL(fileURLWithPath: "/Library/Logs/Macximesed")
    public static let logPath = logDir.appendingPathComponent("daemon.log")
    public static let statusPath = logDir.appendingPathComponent("status.json")

    public let executable: URL
    public let user: WatchUser
    public let suspend: Bool
    public var plistPath: URL { Self.plistPath }

    /// Check finished downloads (on unless turned off).
    public let downloads: Bool
    /// How much the daemon writes to its own log (`MACX_LOG` in the plist; it can't take -v).
    public let logLevel: LogLevel

    public init(executable: URL, user: WatchUser, suspend: Bool, downloads: Bool = true, logLevel: LogLevel = .info) throws {
        guard UpdateInstaller.enclosingApp(of: executable) != nil else { throw Problem.notInApp }
        self.executable = executable
        self.user = user
        self.suspend = suspend
        self.downloads = downloads
        self.logLevel = logLevel
    }

    public var arguments: [String] { ["watch", "--background"] + (suspend ? ["--suspend"] : []) + (downloads ? [] : ["--no-downloads"]) }

    public var plist: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executable.path] + arguments,
            "EnvironmentVariables": ["MACX_OWN_RESPONSIBILITY": "0", "MACX_NO_UPDATE_CHECK": "1", "MACX_USER": user.name]
                .merging(logLevel == .info ? [:] : ["MACX_LOG": logLevel.name]) { a, _ in a },
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "StandardOutPath": Self.logPath.path,
            "StandardErrorPath": Self.logPath.path,
            "ProcessType": "Interactive",
        ]
    }

    public func plistData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

/// What the installed daemon was set up to do, read from its launchd plist. The plist is root-owned in
/// /Library/LaunchDaemons, so anyone can read these settings and only root can change them: a stealer running as
/// you can't switch the Downloads watch off.
public struct DaemonSettings: Sendable, Equatable {
    public var suspend: Bool
    public var downloads: Bool
    public var logLevel: LogLevel

    public init(suspend: Bool, downloads: Bool, logLevel: LogLevel = .info) {
        self.suspend = suspend
        self.downloads = downloads
        self.logLevel = logLevel
    }

    /// Nil unless it's the plist `macx daemon install` writes (our label, running `macx watch`).
    public init?(plist: [String: Any]) {
        guard plist["Label"] as? String == DaemonPlan.label, let args = plist["ProgramArguments"] as? [String],
            args.dropFirst().first == "watch"
        else { return nil }
        suspend = args.contains("--suspend")
        downloads = !args.contains("--no-downloads")
        logLevel = ((plist["EnvironmentVariables"] as? [String: String])?["MACX_LOG"]).flatMap(LogLevel.init(name:)) ?? .info
    }

    public static func read(from url: URL = DaemonPlan.plistPath) -> DaemonSettings? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return DaemonSettings(plist: plist)
    }

    /// The same plist with the Downloads watch switched on or off. Everything else (the program, the user,
    /// freezing, launchd's keys) stays as installed.
    public static func plist(_ plist: [String: Any], downloads: Bool) -> [String: Any]? {
        guard DaemonSettings(plist: plist) != nil, var args = plist["ProgramArguments"] as? [String] else { return nil }
        args.removeAll { $0 == "--no-downloads" }
        if !downloads { args.append("--no-downloads") }
        var out = plist
        out["ProgramArguments"] = args
        return out
    }

    /// The same plist with the daemon's log level changed (`MACX_LOG`); everything else stays as installed.
    public static func plist(_ plist: [String: Any], logLevel: LogLevel) -> [String: Any]? {
        guard DaemonSettings(plist: plist) != nil else { return nil }
        var env = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        env["MACX_LOG"] = logLevel == .info ? nil : logLevel.name
        var out = plist
        out["EnvironmentVariables"] = env
        return out
    }

    /// `macx daemon install` writes a fresh plist. To change freezing, it must carry over a Downloads watch that
    /// was switched off and a raised log level, or reinstalling would quietly reset them.
    public static func installArguments(suspend: Bool, keeping current: DaemonSettings?) -> [String] {
        ["daemon", "install"] + (suspend ? ["--suspend"] : []) + (current?.downloads == false ? ["--no-downloads"] : [])
            + (current.map { $0.logLevel == .info ? [] : ["--log-level", $0.logLevel.name] } ?? [])
    }
}

/// What the daemon last said about itself, readable by anyone (no sudo needed for `macx daemon status`).
public struct DaemonStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case starting, watching, refused, stopped }
    public var state: State
    public var message: String
    public var since: Date

    public init(state: State, message: String, since: Date = Date()) {
        self.state = state
        self.message = message
        self.since = since
    }

    public func write(to url: URL = DaemonPlan.statusPath) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(self).write(to: url, options: .atomic)
        chmod(url.path, 0o644)
    }

    public static func read(from url: URL = DaemonPlan.statusPath) -> DaemonStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(DaemonStatus.self, from: data)
    }
}

/// Shows an alert as a notification on the user's screen, from a root daemon: osascript started in the
/// user's login session (`launchctl asuser`) as the user.
public enum AlertNotifier {
    public struct Command: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func command(user: WatchUser, title: String, message: String) -> Command {
        let body = String(message.replacingOccurrences(of: "\n", with: " ").prefix(240))
        let script = "display notification \(quoted(body)) with title \(quoted(title))"
        return Command(
            executable: "/bin/launchctl",
            arguments: ["asuser", String(user.uid), "/usr/bin/sudo", "-u", user.name, "/usr/bin/osascript", "-e", script])
    }

    public static func notify(user: WatchUser, title: String, message: String) {
        let c = command(user: user, title: title, message: message)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.executable)
        p.arguments = c.arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()  // fire and forget: the watch loop never waits on the screen
    }
}

/// One line of the alert log (`~/Library/Logs/Macximesed/watch.jsonl`).
public struct AlertRecord: Sendable, Equatable {
    public var time: Date
    public var rule: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var process: String
    /// The program named belongs to macOS: never the thing to delete.
    public var isSystemProgram: Bool { WatchAlert.isSystemPath(process) }

    public static func parse(_ text: String) -> [AlertRecord] {
        text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let rule = obj["rule"] as? String, let title = obj["title"] as? String
            else { return nil }
            let sev = Severity.allCases.first { String(describing: $0) == (obj["severity"] as? String) } ?? .info
            return AlertRecord(
                time: Date(timeIntervalSince1970: obj["epoch"] as? Double ?? 0), rule: rule, severity: sev, title: title,
                detail: obj["detail"] as? String ?? "", process: obj["process"] as? String ?? "")
        }
    }
}

/// At most one notification per window; the next one after it says how many were held back (they're all in
/// the alert log). One pasted command can raise three alerts in the same second.
public struct NotificationThrottle: Sendable {
    let window: TimeInterval
    var last: Date?
    var held = 0

    public init(window: TimeInterval = 10) { self.window = window }

    public mutating func offer(_ message: String, now: Date = Date()) -> String? {
        if let last, now.timeIntervalSince(last) < window {
            held += 1
            return nil
        }
        last = now
        defer { held = 0 }
        return held > 0 ? "\(message) (and \(held) more: macx alerts)" : message
    }
}
