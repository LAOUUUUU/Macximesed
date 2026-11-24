import Darwin
import Foundation

/// Whether this run of the one `macx` executable is the Mac app or the command-line tool.
///
/// The app's Info.plist sets `LSEnvironment = {MACX_APP: 1}`, which LaunchServices applies only when the app is
/// opened from Finder, the Dock, `open` or a login item. A shell run, the daemon and scripts never have it, so
/// they always get the CLI. `macx app` opens the app from a terminal.
public enum LaunchMode: Equatable, Sendable {
    case app, cli

    public static func decide(arguments: [String], environment: [String: String]) -> LaunchMode {
        if arguments == ["app"] { return .app }
        guard environment["MACX_APP"] == "1" else { return .cli }
        let real = arguments.filter { !$0.hasPrefix("-psn_") }
        return real.isEmpty ? .app : .cli
    }
}

/// Alerts with the same rule and the same program, folded into one row. A day of development can log
/// hundreds of identical alerts; a flat list of them would hide the one that matters.
public struct AlertGroup: Sendable, Equatable, Identifiable {
    public var rule: String
    public var process: String
    public var severity: Severity
    public var count: Int
    public var first: Date
    public var last: Date
    public var latest: AlertRecord

    public var key: String { "\(rule)|\(process)" }
    public var id: String { key }
}

public enum AlertGroups {
    /// Groups by rule + program, most severe first, then most recent. Bookkeeping lines ("frozen") are left out,
    /// and so are groups in `expected`, except critical ones.
    public static func make(_ records: [AlertRecord], expected: Set<String> = []) -> [AlertGroup] {
        var byKey: [String: AlertGroup] = [:]
        for r in records where r.rule != "frozen" {
            let key = "\(r.rule)|\(r.process)"
            if var g = byKey[key] {
                g.count += 1
                g.severity = max(g.severity, r.severity)
                if r.time < g.first { g.first = r.time }
                if r.time >= g.last {
                    g.last = r.time
                    g.latest = r
                }
                byKey[key] = g
            } else {
                byKey[key] = AlertGroup(
                    rule: r.rule, process: r.process, severity: r.severity, count: 1, first: r.time, last: r.time, latest: r)
            }
        }
        return byKey.values
            .filter { $0.severity == .critical || !expected.contains($0.key) }
            .sorted { a, b in a.severity != b.severity ? a.severity > b.severity : (a.last != b.last ? a.last > b.last : a.key < b.key) }
    }

    /// Critical alerts always show: a stealer could otherwise use the list to hide itself.
    public static func canMarkExpected(_ g: AlertGroup) -> Bool { g.severity < .critical }

    public static func filter(_ groups: [AlertGroup], seriousOnly: Bool) -> [AlertGroup] {
        seriousOnly ? groups.filter { $0.severity >= .high } : groups
    }
}

/// Programs the user said are expected for a rule (the app hides their groups; the daemon still logs and
/// notifies). Stored per user in Application Support.
public struct ExpectedPrograms: Sendable {
    public struct Refused: Error {}

    public let file: URL
    public private(set) var keys: Set<String>

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/expected.json")
    }

    public init(file: URL = ExpectedPrograms.defaultFile) {
        self.file = file
        let list = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        keys = Set(list)
    }

    public mutating func add(_ g: AlertGroup) throws {
        guard AlertGroups.canMarkExpected(g) else { throw Refused() }
        keys.insert(g.key)
        try save()
    }

    public mutating func remove(key: String) throws {
        keys.remove(key)
        try save()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys.sorted()).write(to: file, options: .atomic)
    }
}

/// Reads new alert lines as they are appended to `watch.jsonl`, starting from the top after the file shrinks.
public struct AlertTail: Sendable {
    public let file: URL
    var offset: UInt64 = 0
    var pending = Data()

    public init(file: URL) { self.file = file }

    public mutating func readNew() -> [AlertRecord] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset {
            offset = 0
            pending.removeAll()
        }
        guard size > offset else { return [] }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        offset += UInt64(data.count)
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: 0x0A) else { return [] }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        return AlertRecord.parse(String(decoding: complete, as: UTF8.self))
    }
}

/// What `launchctl print system/<label>` says (it answers without root).
public struct LaunchdInfo: Sendable, Equatable {
    public var state: String?
    public var pid: Int?

    public static func parse(_ output: String) -> LaunchdInfo {
        var info = LaunchdInfo()
        for raw in output.split(separator: "\n") {
            // Only the job's own top-level keys (one tab in), not nested endpoint states.
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if info.state == nil, line.hasPrefix("state = ") { info.state = String(line.dropFirst(8)) }
            if info.pid == nil, line.hasPrefix("pid = ") { info.pid = Int(line.dropFirst(6)) }
        }
        return info
    }
}

/// The background watch as the app and the menu bar show it.
public enum WatchState: Sendable, Equatable {
    case watching(since: Date)
    case paused(until: Date)
    case starting
    case refused(message: String)
    case notRunning
    case notInstalled

    public enum Glyph: Sendable, Equatable { case watching, paused, off }

    public static func derive(installed: Bool, running: Bool, status: DaemonStatus?, pausedUntil: Date?, now: Date) -> WatchState {
        guard installed || running else { return .notInstalled }
        if !running {
            if let status, status.state == .refused { return .refused(message: status.message) }
            return .notRunning
        }
        if let until = pausedUntil, until > now { return .paused(until: until) }
        switch status?.state {
        case .watching: return .watching(since: status?.since ?? now)
        case .refused: return .refused(message: status?.message ?? "")
        case .starting, .stopped, nil: return .starting
        }
    }

    public var headline: String {
        switch self {
        case .watching: "Watching."
        case .paused(let until): "Paused until \(Self.clock(until))."
        case .starting: "Starting."
        case .refused: "Can't watch."
        case .notRunning: "Not running."
        case .notInstalled: "Not watching."
        }
    }

    public var glyph: Glyph {
        switch self {
        case .watching, .starting: .watching
        case .paused: .paused
        case .refused, .notRunning, .notInstalled: .off
        }
    }

    public static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
        return f.string(from: d)
    }
}

/// A pause of the background watch. Only root can write it (`sudo macx daemon pause`), into the root-owned
/// log folder, and it always ends by itself: if any user-writable file could pause the watch, so could a stealer.
public enum WatchPause {
    public static let file = DaemonPlan.logDir.appendingPathComponent("pause.json")
    public static let longest: TimeInterval = 86_400

    /// "1h", "30m", or a number of minutes. At most a day.
    public static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        let seconds: Double?
        if t.hasSuffix("h") {
            seconds = Double(t.dropLast()).map { $0 * 3600 }
        } else if t.hasSuffix("m") {
            seconds = Double(t.dropLast()).map { $0 * 60 }
        } else {
            seconds = Double(t).map { $0 * 60 }
        }
        guard let seconds, seconds > 0, seconds <= longest else { return nil }
        return seconds
    }

    struct Record: Codable { var until: Double }

    public static func write(until: Date, to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Record(until: until.timeIntervalSince1970)).write(to: url, options: .atomic)
        chmod(url.path, 0o644)
    }

    public static func clear(_ url: URL = file) { try? FileManager.default.removeItem(at: url) }

    /// When the pause ends, if one is in force: the file must belong to `trustedOwner` (root), be writable
    /// by nobody else, and end within a day.
    public static func activeUntil(file url: URL = file, now: Date = Date(), trustedOwner: uid_t = 0) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == trustedOwner,
            st.st_mode & (S_IWGRP | S_IWOTH) == 0,
            let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        let until = Date(timeIntervalSince1970: r.until)
        guard until > now, until.timeIntervalSince(now) <= longest + 60 else { return nil }
        return until
    }
}

/// Runs one of the app's own root commands through the standard administrator prompt.
public enum AdminCommand {
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func appleScript(executable: String, arguments: [String]) -> String {
        let shell = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
