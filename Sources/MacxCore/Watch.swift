import Foundation

// MARK: - Events (eslogger JSON, modelled on es_message_t)

public struct ESProcessInfo: Sendable, Equatable {
    public var path: String
    public var pid: Int?
    public var ppid: Int?
    public var isPlatform: Bool
    public var teamID: String?
    public var signingID: String?

    /// Not Apple's and not signed by a developer with a team ID.
    public var isUnsignedThirdParty: Bool { !isPlatform && (teamID ?? "").isEmpty }

    static func parse(_ any: Any?) -> ESProcessInfo? {
        guard let d = any as? [String: Any], let exe = d["executable"] as? [String: Any], let path = exe["path"] as? String else {
            return nil
        }
        let pid = ((d["audit_token"] as? [String: Any])?["pid"] as? Int) ?? (d["pid"] as? Int)
        return ESProcessInfo(
            path: path, pid: pid, ppid: d["ppid"] as? Int, isPlatform: (d["is_platform_binary"] as? Bool) ?? false,
            teamID: d["team_id"] as? String, signingID: d["signing_id"] as? String)
    }
}

/// One eslogger line. The event type is read from the key inside `event` (more stable than the number),
/// and every field is optional: eslogger's man page says its JSON may change between releases.
public struct ESEvent: Sendable, Equatable {
    public var kind: String
    public var process: ESProcessInfo?
    public var target: ESProcessInfo?
    public var args: [String] = []
    public var filePath: String?
    public var sourcePath: String?
    public var extattr: String?
    public var itemURL: String?
    public var executablePath: String?
    public var instigator: ESProcessInfo?

    public static func parse(_ line: String) -> ESEvent? {
        guard let data = line.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let events = root["event"] as? [String: Any], let (kind, rawBody) = events.first
        else { return nil }
        let body = rawBody as? [String: Any] ?? [:]
        var e = ESEvent(kind: kind, process: ESProcessInfo.parse(root["process"]))

        func path(_ any: Any?) -> String? { (any as? [String: Any])?["path"] as? String }
        func destination(_ d: [String: Any]) -> String? {
            guard let dest = d["destination"] as? [String: Any] else { return nil }
            if let existing = path(dest["existing_file"]) { return existing }
            if let np = dest["new_path"] as? [String: Any], let dir = path(np["dir"]), let name = np["filename"] as? String {
                return (dir as NSString).appendingPathComponent(name)
            }
            return nil
        }

        switch kind {
        case "exec":
            e.target = ESProcessInfo.parse(body["target"])
            e.args = (body["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        case "create":
            e.filePath = destination(body)
        case "rename":
            e.sourcePath = path(body["source"])
            e.filePath = destination(body)
        case "deleteextattr", "setextattr":
            e.filePath = path(body["target"])
            e.extattr = body["extattr"] as? String
        case "btm_launch_item_add":
            e.instigator = ESProcessInfo.parse(body["instigator"])
            e.itemURL = (body["item"] as? [String: Any])?["item_url"] as? String
            e.executablePath = body["executable_path"] as? String
        default:
            break
        }
        return e
    }
}

// MARK: - Rules

public struct WatchAlert: Sendable, Equatable {
    public var rule: String
    public var severity: Severity
    public var title: String
    public var detail: String?
    /// The process to stop if the user asked to suspend on alerts.
    public var pid: Int?
    public var processPath: String?

    public init(rule: String, severity: Severity, title: String, detail: String?, pid: Int?, processPath: String?) {
        self.rule = rule
        self.severity = severity
        self.title = title
        self.detail = detail
        self.pid = pid
        self.processPath = processPath
    }
}

/// The live versions of the persistence and paste rules: they fire as things happen, not on the next scan.
public struct WatchRules: Sendable {
    public var home: URL
    public var signatures: SignatureChecking
    /// Known-malware hashes. Non-Apple programs are hashed as they start (cached by path and change time).
    public var feed: HashFeed?
    let hashes = ExecHashCache()

    /// eslogger events the rules use. `open` is left out: it's far too noisy to watch live.
    public static let events = ["exec", "create", "rename", "deleteextattr", "btm_launch_item_add"]

    public init(home: URL, signatures: SignatureChecking = GuardedSignatureChecker(), feed: HashFeed? = nil) {
        self.home = home
        self.signatures = signatures
        self.feed = feed
    }

    public func evaluate(_ e: ESEvent) -> [WatchAlert] {
        var out: [WatchAlert] = []
        let actor = e.kind == "exec" ? (e.target ?? e.process) : e.process
        func add(_ rule: String, _ sev: Severity, _ title: String, _ detail: String? = nil, pid: Int? = nil) {
            out.append(
                WatchAlert(rule: rule, severity: sev, title: title, detail: detail, pid: pid ?? actor?.pid, processPath: actor?.path))
        }
        let h = home.standardizedFileURL.path

        switch e.kind {
        case "exec":
            let command = Self.redact(e.args).joined(separator: " ")
            let result = PasteGuard.check(e.args.joined(separator: " "))
            for p in result.patterns.sorted(by: { $0.rawValue < $1.rawValue }) {
                var detail = String(command.prefix(300))
                if !result.decoded.isEmpty { detail += "\n  decodes to: " + result.decoded.joined(separator: "\n  decodes to: ") }
                add(p.rawValue, p.severity, p.title, detail)
            }
            if let feed, let t = e.target, !t.isPlatform, let hash = hashes.hash(t.path), let name = try? feed.lookup(sha256: hash) {
                add("known-malware", .critical, "A known malware program started", "\(name)\n  SHA-256 \(hash)\n  \(t.path)")
            }
            if let t = e.target, t.isUnsignedThirdParty, Self.isHiddenOrTemp(t.path, home: h) {
                add("exec-from-hidden-or-temp", .high, "An unsigned program started from a hidden or temporary folder", t.path)
            }

        case "create", "rename":
            guard let path = e.filePath else { break }
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let launchDirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "\(h)/Library/LaunchAgents"]
            if launchDirs.contains(dir), name.hasSuffix(".plist") {
                if name.hasPrefix("com.apple."), !(e.process?.isPlatform ?? false) {
                    add(
                        "fake-apple-launch-item", .critical, "A non-Apple program created an Apple-named launch item (the AMOS disguise)",
                        path)
                } else {
                    add("new-launch-item", .medium, "Something set itself to start automatically", path)
                }
            }
            if dir == "\(h)/Library/Application Support", name.hasPrefix(".com.apple.") {
                add("fake-apple-folder", .critical, "Hidden Apple-named folder created in your Application Support (AMOS hides here)", path)
            }

        case "deleteextattr":
            if e.extattr == "com.apple.quarantine" {
                add(
                    "quarantine-removed", .high, "The download-safety (quarantine) flag was removed, so macOS won't check this file",
                    e.filePath)
            }

        case "btm_launch_item_add":
            let what = e.executablePath ?? e.itemURL ?? "unknown item"
            add("new-background-item", .medium, "A new login or background item was registered", what, pid: e.instigator?.pid)
            if let exe = e.executablePath {
                let sig = signatures.check(exe)
                if sig == .adHoc || sig == .unsigned {
                    add(
                        "new-background-item-unsigned", .high, "The new background item runs an \(sig.label) program", exe,
                        pid: e.instigator?.pid)
                }
            }

        default:
            break
        }
        return out.sorted { $0.severity > $1.severity }
    }

    static func isHiddenOrTemp(_ path: String, home: String) -> Bool {
        let temp = ["/tmp/", "/private/tmp/", "/private/var/tmp/", "/var/tmp/", "/Users/Shared/", "\(home)/Downloads/"]
        if temp.contains(where: { path.hasPrefix($0) }) { return true }
        return path.split(separator: "/").dropLast().contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    /// Hides what follows `-authonly <user>` (the password being checked) and `-p`/`--password` values.
    static func redact(_ args: [String]) -> [String] {
        var out = args
        for (i, a) in args.enumerated() {
            if a == "-authonly", i + 2 < args.count { for j in (i + 2)..<args.count { out[j] = "********" } }
            if a == "-p" || a == "--password" || a == "-password", i + 1 < args.count { out[i + 1] = "********" }
        }
        return out
    }
}

/// SHA-256 of program files, remembered by path, size and change time, so each program is hashed once.
final class ExecHashCache: @unchecked Sendable {
    private var cache: [String: (UInt64, Date, String)] = [:]
    private let lock = NSLock()

    func hash(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attrs[.size] as? NSNumber)?.uint64Value, let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        lock.lock()
        if let c = cache[path], c.0 == size, c.1 == mtime {
            lock.unlock()
            return c.2
        }
        lock.unlock()
        guard size < 500_000_000, let h = FileChecker.hashFile(URL(fileURLWithPath: path)) else { return nil }
        lock.lock()
        cache[path] = (size, mtime, h)
        lock.unlock()
        return h
    }
}
