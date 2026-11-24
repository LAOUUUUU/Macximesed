import Darwin
import Foundation
import os

// macx's own log: plain text files it writes itself, so a bug report can include the lines from the run that went
// wrong. Apple's unified log keeps no debug lines and shows inserted text as <private>, so it only gets a copy of
// warnings and errors. Research: research/diagnostics-beta/RESEARCH.md.

public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case trace, debug, info, warning, error

    public init?(name: String) {
        switch name.lowercased() {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "warning", "warn": self = .warning
        case "error": self = .error
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .trace: "trace"
        case .debug: "debug"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Which macx is writing: each has its own file, so two processes never rotate the same one.
public enum LogRole: String, Sendable {
    case cli, app, daemon

    /// Root never writes into a home folder (the file would end up root-owned there, and the folder is the user's).
    public func file(home: URL, isRoot: Bool) -> URL {
        switch self {
        case .daemon: return LogFile.rootFolder.appendingPathComponent("watch.log")
        case .cli, .app:
            if isRoot { return LogFile.rootFolder.appendingPathComponent("\(rawValue)-root.log") }
            return home.appendingPathComponent("Library/Logs/Macximesed/\(rawValue).log")
        }
    }

    /// The launchd daemon runs `macx watch --background`; everything else from a shell is the CLI.
    public static func of(arguments: [String]) -> LogRole {
        arguments.first == "watch" && arguments.contains("--background") ? .daemon : .cli
    }

    /// The command and subcommand (`guard inspect`), never their arguments: paths, links and pasted commands stay
    /// out of the log.
    public static func commandName(_ arguments: [String]) -> String {
        let words = arguments.prefix(2).prefix { $0.range(of: "^[a-z][a-z-]*$", options: .regularExpression) != nil }
        return words.isEmpty ? "(none)" : words.joined(separator: " ")
    }
}

/// How much to log, from `-v` / `-vv` / `--verbose` and `MACX_LOG`. The flags are taken out of the arguments so
/// every command accepts them, but only before `--`: after it, they belong to the command being checked.
public struct LogSettings: Sendable, Equatable {
    public var level: LogLevel
    /// Also show debug and trace lines on the terminal (only when asked for with a flag).
    public var echo: Bool
    public var arguments: [String]

    public static func from(arguments: [String], environment: [String: String]) -> LogSettings {
        var rest: [String] = []
        var count = 0
        var afterDash = false
        for a in arguments {
            if afterDash {
                rest.append(a)
                continue
            }
            switch a {
            case "--":
                afterDash = true
                rest.append(a)
            case "-v", "--verbose": count += 1
            case "-vv": count += 2
            default: rest.append(a)
            }
        }
        let flag: LogLevel? = count >= 2 ? .trace : (count == 1 ? .debug : nil)
        let env = environment["MACX_LOG"].flatMap(LogLevel.init(name:)) ?? .info
        return LogSettings(level: min(flag ?? .info, env), echo: flag != nil, arguments: rest)
    }
}

public enum LogLine {
    /// `2026-11-24T10:00:00Z DEBUG cli[42] update: checked`, one line per entry.
    public static func format(
        time: Date, level: LogLevel, role: LogRole, pid: Int32, category: String, message: String, homes: [String]
    ) -> String {
        var m = message
        for home in homes where home.count > 1 { m = tilde(m, home: home) }
        // An entry can't make another one: newlines are written as \n.
        m = m.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "\(time.formatted(.iso8601)) \(level.name.uppercased()) \(role.rawValue)[\(pid)] \(category): \(m)\n"
    }

    /// `/Users/v/x` becomes `~/x`, but `/Users/vv` stays as it is.
    static func tilde(_ text: String, home: String) -> String {
        let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?=[/\s"'),;:\]]|$)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }
}

/// One size-capped log file. Each line is appended through a fresh descriptor that never follows a symlink, and
/// root only writes into a folder that only root can change.
public final class LogFile: @unchecked Sendable {
    public static let rootFolder = URL(fileURLWithPath: "/Library/Logs/Macximesed")

    let url: URL
    let maxBytes: Int
    let keep: Int
    let requireRootOwned: Bool
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int = 1_000_000, keep: Int = 2, requireRootOwned: Bool) {
        self.url = url
        self.maxBytes = maxBytes
        self.keep = keep
        self.requireRootOwned = requireRootOwned
    }

    static func isSafeFolder(owner: uid_t, mode: mode_t, requireRootOwned: Bool) -> Bool {
        !requireRootOwned || (owner == 0 && mode & 0o022 == 0)
    }

    func rotated(_ n: Int) -> URL {
        n == 0
            ? url
            : url.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension(url.pathExtension)
    }

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: requireRootOwned ? [.posixPermissions: 0o755] : nil)
        var st = stat()
        guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
            Self.isSafeFolder(owner: st.st_uid, mode: st.st_mode & 0o777, requireRootOwned: requireRootOwned)
        else { return }

        let data = Data(line.utf8)
        var current = stat()
        if lstat(url.path, &current) == 0, current.st_size > 0, Int(current.st_size) + data.count > maxBytes {
            for n in stride(from: keep, to: 0, by: -1) { rename(rotated(n - 1).path, rotated(n).path) }
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
            !requireRootOwned || opened.st_uid == 0
        else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// Formats entries at or above its level and hands them to a sink. The message isn't built below the level.
public struct LogWriter: Sendable {
    public var level: LogLevel
    public var role: LogRole
    public var homes: [String]
    let sink: @Sendable (String) -> Void

    public init(level: LogLevel, role: LogRole, homes: [String], sink: @escaping @Sendable (String) -> Void) {
        self.level = level
        self.role = role
        self.homes = homes
        self.sink = sink
    }

    public func log(_ level: LogLevel, _ category: String, _ message: () -> String) {
        guard level >= self.level else { return }
        sink(LogLine.format(time: Date(), level: level, role: role, pid: getpid(), category: category, message: message(), homes: homes))
    }

    public func trace(_ category: String, _ message: @autoclosure () -> String) { log(.trace, category, message) }
    public func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: @autoclosure () -> String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: @autoclosure () -> String) { log(.error, category, message) }
}

/// The process's log, set up once at start (`Log.start`). Until then, and in tests, nothing is written.
public enum Log {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var writer: LogWriter?
    }
    static let state = State()
    public static let subsystem = "dev.macximesed.macx"

    /// `homes`: folders written as `~` (the daemon's lines are about the user's home, not root's).
    public static func start(role: LogRole, settings: LogSettings, home: URL, homes: [String], isRoot: Bool = geteuid() == 0) {
        let file = LogFile(url: role.file(home: home, isRoot: isRoot), requireRootOwned: isRoot)
        let echo = settings.echo
        let writer = LogWriter(level: settings.level, role: role, homes: homes) { line in
            file.append(line)
            if echo, line.contains(" DEBUG ") || line.contains(" TRACE ") {
                FileHandle.standardError.write(Data(("macx: " + line).utf8))
            }
            // Warnings and errors also go to the system log, so `log show` and sysdiagnose see them. The line is
            // already scrubbed, so it can be public there.
            if line.contains(" WARNING ") || line.contains(" ERROR ") {
                let trimmed = line.trimmingCharacters(in: .newlines)
                os.Logger(subsystem: subsystem, category: role.rawValue)
                    .log(level: line.contains(" ERROR ") ? .error : .default, "\(trimmed, privacy: .public)")
            }
        }
        state.lock.lock()
        state.writer = writer
        state.lock.unlock()
    }

    static var writer: LogWriter? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.writer
    }

    public static var level: LogLevel { writer?.level ?? .info }

    public static func trace(_ category: String, _ message: @autoclosure () -> String) { writer?.log(.trace, category, message) }
    public static func debug(_ category: String, _ message: @autoclosure () -> String) { writer?.log(.debug, category, message) }
    public static func info(_ category: String, _ message: @autoclosure () -> String) { writer?.log(.info, category, message) }
    public static func warning(_ category: String, _ message: @autoclosure () -> String) { writer?.log(.warning, category, message) }
    public static func error(_ category: String, _ message: @autoclosure () -> String) { writer?.log(.error, category, message) }
}
