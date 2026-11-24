import Darwin
import Foundation

// Bug and crash reports, built on the Mac and shown in full before anything leaves it. The report is plain text,
// and that exact text is what gets sent. Research and Lao's decisions: research/diagnostics-beta/RESEARCH.md.

// MARK: - Redaction

/// Takes personal details out of report text. Reports are built from known fields first; this is the second pass
/// over the free text in them (log lines, crash text, what the person wrote).
public struct ReportRedactor: Sendable {
    /// Home folders: ours becomes `~`, anyone else's `/Users/<user>`.
    public var homes: [String]
    /// The account name and the full name.
    public var names: [String]
    /// The computer name and local host name.
    public var hosts: [String]
    /// Keep file names under personal folders (otherwise `~/Documents/….pdf`).
    public var keepFileNames = false
    /// Keep app names (otherwise `/Applications/<app>.app`).
    public var keepProgramNames = false

    public init(homes: [String], names: [String], hosts: [String]) {
        self.homes = homes
        self.names = names
        self.hosts = hosts
    }

    /// Folders under home whose paths are kept: launch items and app data there are what bugs are about.
    static let keptTopFolders: Set<String> = ["Library", "Applications", ".local", ".config"]

    /// Compiled once. NSRegularExpression is thread-safe; the holder makes that explicit on every SDK.
    final class Patterns: @unchecked Sendable {
        let otherHome = try! NSRegularExpression(pattern: #"/Users/(?!Shared(?:/|\b))(?!<user>)[^/\s"']+"#)
        let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        /// `~/Top/rest`: the rest runs to a file extension followed by a break, or else to the next space.
        let homeFile = try! NSRegularExpression(
            pattern: #"~/([^/\n"']+)/((?:[^\n"']*?\.[A-Za-z0-9]{1,6}(?=[\s"'),;:\]]|$))|[^\s"']+)"#, options: [.anchorsMatchLines])
        let app = try! NSRegularExpression(pattern: #"/Applications/([^/\n"']+?)\.app\b"#)
        let mac = try! NSRegularExpression(pattern: #"(?<![\w:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![\w:])"#)
        let ipv6 = try! NSRegularExpression(
            pattern: #"(?<![\w:.])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){7})[0-9A-Fa-f:]{3,39}(?![\w:])"#)
        let ipv4 = try! NSRegularExpression(pattern: #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#)
        let sha256 = try! NSRegularExpression(pattern: #"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])"#)
    }
    static let patterns = Patterns()

    public func redact(_ input: String) -> (String, Int) {
        var text = input
        var count = 0
        /// Replaces each match with what `transform` returns (nil keeps it), back to front so ranges stay valid.
        func apply(_ re: NSRegularExpression, _ transform: (NSTextCheckingResult, NSString) -> String?) {
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return }
            let out = NSMutableString(string: ns)
            for m in matches.reversed() {
                guard let replacement = transform(m, ns), replacement != ns.substring(with: m.range) else { continue }
                out.replaceCharacters(in: m.range, with: replacement)
                count += 1
            }
            text = out as String
        }
        func words(_ list: [String], as label: String) {
            for word in list.filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
                let pattern = #"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\w.-])"#
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                apply(re) { _, _ in label }
            }
        }

        // Longest first (`/private/tmp/h` before `/tmp/h`), and only at the start of a path.
        for home in homes.filter({ $0.count > 1 }).sorted(by: { $0.count > $1.count }) {
            let pattern = #"(?<![\w.~/-])"# + NSRegularExpression.escapedPattern(for: home) + #"(?=[/\s"'),;:\]]|$)"#
            if let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) { apply(re) { _, _ in "~" } }
        }
        apply(Self.patterns.otherHome) { _, _ in "/Users/<user>" }
        apply(Self.patterns.email) { _, _ in "<email>" }
        if !keepFileNames {
            apply(Self.patterns.homeFile) { m, ns in
                let top = ns.substring(with: m.range(at: 1))
                guard !Self.keptTopFolders.contains(top) else { return nil }
                let ext = (ns.substring(with: m.range(at: 2)) as NSString).pathExtension
                let keepExt = !ext.isEmpty && ext.count <= 6 && ext.allSatisfy { $0.isLetter || $0.isNumber }
                return "~/\(top)/…" + (keepExt ? ".\(ext)" : "")
            }
        }
        if !keepProgramNames {
            apply(Self.patterns.app) { m, ns in ns.substring(with: m.range(at: 1)) == "Macximesed" ? nil : "/Applications/<app>.app" }
        }
        apply(Self.patterns.mac) { _, _ in "<mac>" }
        apply(Self.patterns.ipv6) { _, _ in "<ip>" }
        apply(Self.patterns.ipv4) { m, ns in ["127.0.0.1", "0.0.0.0"].contains(ns.substring(with: m.range)) ? nil : "<ip>" }
        apply(Self.patterns.sha256) { _, _ in "<sha256>" }
        words(hosts, as: "<host>")
        words(names, as: "<user>")
        return (text, count)
    }
}

// MARK: - Crashes

/// What a crash report says about the crash itself, from the `.ips` file macOS writes. The per-Mac crash ID,
/// process IDs, uptime, paths and memory details are left out.
public struct CrashSummary: Sendable, Equatable {
    public var time: Date?
    public var process: String
    public var version: String?
    public var exception: String
    public var termination: String?
    public var frames: [String]
    public var os: String
    public var cpu: String
    /// Identifies the build (for turning addresses back into function names), not the Mac.
    public var imageUUID: String?

    static func json(_ s: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }

    /// Nil unless it's a crash (bug type 309) of macx.
    public static func parse(ips: String) -> CrashSummary? {
        let parts = ips.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let header = json(parts[0]), header["bug_type"] as? String == "309",
            (header["name"] as? String ?? header["app_name"] as? String) == "macx", let body = json(parts[1])
        else { return nil }

        let exc = body["exception"] as? [String: Any] ?? [:]
        var exception = exc["type"] as? String ?? "unknown exception"
        if let sig = exc["signal"] as? String { exception += " (\(sig))" }
        if let sub = exc["subtype"] as? String { exception += " \(sub)" }
        let term = body["termination"] as? [String: Any]

        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting =
            (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"] as? Bool == true }
        let frames = (faulting?["frames"] as? [[String: Any]] ?? []).prefix(30).map { f -> String in
            let i = f["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(i) ? images[i]["name"] as? String ?? "?" : "?"
            if let symbol = f["symbol"] as? String { return "\(image)  \(symbol) + \(f["symbolLocation"] as? Int ?? 0)" }
            return "\(image)  + \(f["imageOffset"] as? Int ?? 0)"
        }

        let osv = body["osVersion"] as? [String: Any]
        let os =
            osv.flatMap { v in (v["train"] as? String).map { "\($0) (\(v["build"] as? String ?? "?"))" } }
            ?? header["os_version"] as? String ?? "macOS (unknown)"
        let cpu = (body["cpuType"] as? String ?? "?") + (body["translated"] as? Bool == true ? " (Rosetta)" : "")
        let version =
            (body["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String
            ?? (header["app_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return CrashSummary(
            time: (header["timestamp"] as? String).flatMap(stamp.date(from:)), process: "macx", version: version,
            exception: exception, termination: term?["indicator"] as? String, frames: frames, os: os, cpu: cpu,
            imageUUID: images.first { $0["name"] as? String == "macx" }?["uuid"] as? String)
    }

    public var text: String {
        var lines = ["Crash: \(time.map(BugReport.minute) ?? "time unknown"), macx \(version ?? "(version unknown)")"]
        lines.append("  \(exception)")
        if let termination { lines.append("  Ended by: \(termination)") }
        lines.append("  \(os), \(cpu)")
        if let imageUUID { lines.append("  macx image UUID: \(imageUUID)") }
        if !frames.isEmpty { lines.append("  Crashed thread:") }
        lines += frames.map { "    \($0)" }
        return lines.joined(separator: "\n")
    }
}

public enum CrashReports {
    /// Where macOS keeps crash reports: yours for the CLI and the app, the computer's (admin-only) for the daemon.
    public static func userFolder(home: URL) -> URL { home.appendingPathComponent("Library/Logs/DiagnosticReports") }
    public static let systemFolder = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")

    /// macx's crash files changed after `since`, oldest first.
    public static func find(in folder: URL, since: Date) -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("macx-") && $0.hasSuffix(".ips") }.sorted().compactMap { name in
            let url = folder.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            return (modified ?? .distantPast) > since ? url : nil
        }
    }

    public static func summaries(in folder: URL, since: Date) -> [CrashSummary] {
        find(in: folder, since: since).compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).flatMap(CrashSummary.parse(ips:))
        }
    }
}

/// Crash summaries the root daemon leaves for the app and `macx report`: it has no screen to ask on, so it never
/// sends anything itself. Root-owned and readable by everyone in real use (`/Library/Logs/Macximesed/crashes`).
public struct CrashQueue: Sendable {
    public static let defaultFolder = LogFile.rootFolder.appendingPathComponent("crashes")
    public var folder: URL

    public init(folder: URL = CrashQueue.defaultFolder) { self.folder = folder }

    public func add(_ summaries: [CrashSummary], role: String) throws {
        guard !summaries.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        if geteuid() == 0 {
            var st = stat()
            guard lstat(folder.path, &st) == 0, st.st_uid == 0, st.st_mode & 0o022 == 0 else { return }
        }
        for s in summaries {
            // Named by time and content, so the same crash found again on the next start isn't added twice.
            let name = "\(Int((s.time ?? Date()).timeIntervalSince1970))-\(sha256(Data(s.text.utf8)).prefix(8)).txt"
            try Data("From the \(role):\n\(s.text)\n".utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
            chmod(folder.appendingPathComponent(name).path, 0o644)
        }
        // Keep the newest 20.
        let all = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".txt") }.sorted()
        for old in all.dropLast(20) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
    }

    public func waiting() -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".txt") }.sorted()
        return names.suffix(10).compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
    }

    /// Summaries added since the app last asked, so it asks about each crash once.
    public func newCount(since: Date) -> Int {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            guard name.hasSuffix(".txt") else { return false }
            let modified = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate]) as? Date
            return (modified ?? .distantPast) > since
        }.count
    }
}

// MARK: - The report

public struct BugReportInput: Sendable {
    public var description: String
    public var facts: [(String, String)]
    public var crashes: [CrashSummary]
    public var queuedCrashes: [String]
    public var alerts: [AlertRecord]
    public var logs: [(String, [String])]

    public init(
        description: String, facts: [(String, String)], crashes: [CrashSummary], queuedCrashes: [String], alerts: [AlertRecord],
        logs: [(String, [String])]
    ) {
        self.description = description
        self.facts = facts
        self.crashes = crashes
        self.queuedCrashes = queuedCrashes
        self.alerts = alerts
        self.logs = logs
    }
}

public enum BugReport {
    public static let maxBytes = 256_000

    static func minute(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// The report text and how many personal details were taken out. Alerts carry only their time, severity and
    /// rule; log lines are redacted, and the oldest go first when the report is too big.
    public static func build(
        _ input: BugReportInput, redactor: ReportRedactor, created: Date, maxBytes: Int = maxBytes
    ) -> (text: String, redactions: Int) {
        var count = 0
        func clean(_ s: String) -> String {
            let (out, n) = redactor.redact(s)
            count += n
            return out
        }

        var body = "\n## What happened\n" + (input.description.isEmpty ? "(nothing written)" : clean(input.description)) + "\n"
        body += "\n## This Mac\n" + input.facts.map { "\($0.0): \(clean($0.1))" }.joined(separator: "\n") + "\n"
        let crashTexts = input.crashes.map { clean($0.text) } + input.queuedCrashes.map { clean($0.trimmingCharacters(in: .newlines)) }
        body += "\n## Crashes (\(crashTexts.count))\n" + (crashTexts.isEmpty ? "None found." : crashTexts.joined(separator: "\n\n")) + "\n"
        body += "\n## Recent alerts (\(input.alerts.count))\n"
        body += input.alerts.map {
            "\(minute($0.time))  \(String(describing: $0.severity))  \($0.rule)  (\($0.isSystemProgram ? "part of macOS" : "another program"))"
        }.joined(separator: "\n")
        body += input.alerts.isEmpty ? "None.\n" : "\n"

        // Logs last: they're what gets cut to fit.
        var logs = input.logs.map { (name: $0.0, lines: $0.1.suffix(1000).map(clean)) }
        let shown = input.logs.map(\.1.count)
        func size(_ l: [(name: String, lines: [String])]) -> Int {
            l.reduce(0) { $0 + $1.name.utf8.count + 40 + $1.lines.reduce(0) { $0 + $1.utf8.count + 1 } }
        }
        let fixed = body.utf8.count + 400
        while fixed + size(logs) > maxBytes, let i = logs.indices.max(by: { logs[$0].lines.count < logs[$1].lines.count }),
            !logs[i].lines.isEmpty
        {
            logs[i].lines.removeFirst(max(1, logs[i].lines.count / 10))
        }
        body += "\n## Logs\n" + (logs.isEmpty ? "None found.\n" : "")
        for (i, log) in logs.enumerated() {
            let cut = log.lines.count < shown[i] ? " (last \(log.lines.count) lines)" : ""
            body += "\n### \(log.name)\(cut)\n" + log.lines.joined(separator: "\n") + "\n"
        }

        let head =
            "Macximesed bug report (format 1)\nCreated: \(minute(created)) UTC\n"
            + "Removed before sending: \(count) personal details (home folder, names, file names, addresses).\n"
        return (head + body, count)
    }
}

/// The report settings, in Application Support: whether to ask after a crash, and which crashes were offered.
public struct ReportState: Codable, Sendable, Equatable {
    public var askAfterCrash: Bool
    public var lastCrashSeen: Date?

    public init(askAfterCrash: Bool = true, lastCrashSeen: Date? = nil) {
        self.askAfterCrash = askAfterCrash
        self.lastCrashSeen = lastCrashSeen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        askAfterCrash = try c.decodeIfPresent(Bool.self, forKey: .askAfterCrash) ?? true
        lastCrashSeen = try c.decodeIfPresent(Date.self, forKey: .lastCrashSeen)
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/report-state.json")
    }

    public static func load(from file: URL = defaultFile) -> ReportState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: file)).flatMap { try? dec.decode(ReportState.self, from: $0) } ?? ReportState()
    }

    public func save(to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(self).write(to: file, options: .atomic)
    }
}
