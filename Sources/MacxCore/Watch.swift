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
    /// For exec: the script an interpreter was started for through its #! line (es_event_exec_t.script).
    public var script: String?
    public var filePath: String?
    public var sourcePath: String?
    public var extattr: String?
    public var itemURL: String?
    public var executablePath: String?
    public var instigator: ESProcessInfo?
    /// When it happened (eslogger's `time`), if the line had one.
    public var time: Date?
    /// The event's own fields, flattened to dotted keys ("profile.display_name", "member.member_value.name"), for the
    /// events read by `WatchRules.evaluateMore`. Numbers and bools are kept as text; byte arrays as hex.
    public var fields: [String: String] = [:]

    /// A cheap text check before decoding: most of eslogger's stream on a busy Mac is file creates in caches and
    /// temp folders, which no rule reads. Those are skipped without JSON parsing; every other event is kept. A create
    /// or rename matters only in a folder named LaunchAgents/LaunchDaemons, Application Support (both WatchRules) or
    /// Downloads (DownloadWatch); no slashes in the needles, because eslogger writes them as `\/`.
    public static func worthDecoding(_ line: String) -> Bool {
        var line = line
        return line.withUTF8 { bytes in
            func has(_ needle: StaticString) -> Bool {
                memmem(bytes.baseAddress, bytes.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
            }
            guard has(#""event":{"create""#) || has(#""event":{"rename""#) else { return true }
            return has("LaunchAgents") || has("LaunchDaemons") || has("Application Support") || has("Downloads")
        }
    }

    public static func parse(_ line: String) -> ESEvent? {
        guard let data = line.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let events = root["event"] as? [String: Any], let (kind, rawBody) = events.first
        else { return nil }
        let body = rawBody as? [String: Any] ?? [:]
        var e = ESEvent(kind: kind, process: ESProcessInfo.parse(root["process"]))
        e.time = (root["time"] as? String).flatMap(Self.parseTime)

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
            e.script = path(body["script"])
        case "create":
            e.filePath = destination(body)
        case "rename":
            e.sourcePath = path(body["source"])
            e.filePath = destination(body)
        case "deleteextattr", "setextattr":
            e.filePath = path(body["target"])
            e.extattr = body["extattr"] as? String
        case "open":
            e.filePath = path(body["file"])
        case "btm_launch_item_add":
            e.instigator = ESProcessInfo.parse(body["instigator"])
            e.itemURL = (body["item"] as? [String: Any])?["item_url"] as? String
            e.executablePath = body["executable_path"] as? String
        default:
            guard WatchRules.moreEvents.contains(kind) else { break }
            e.instigator = ESProcessInfo.parse(body["instigator"])
            e.target = ESProcessInfo.parse(body["target"])
            e.fields = Self.flatten(body)
        }
        return e
    }

    /// Dotted keys to text. Arrays of small numbers (es_sha256_t as bytes) become hex; process objects are kept out
    /// (they're read as ESProcessInfo), and depth is capped so an odd line can't blow up.
    static func flatten(_ d: [String: Any], prefix: String = "", depth: Int = 0) -> [String: String] {
        var out: [String: String] = [:]
        guard depth < 5 else { return out }
        for (k, v) in d {
            let key = prefix.isEmpty ? k : prefix + "." + k
            switch v {
            case let s as String: out[key] = s
            case let n as NSNumber:
                out[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            case let sub as [String: Any]:
                if sub["executable"] != nil, sub["audit_token"] != nil { continue }
                out.merge(flatten(sub, prefix: key, depth: depth + 1)) { a, _ in a }
            case let arr as [Any]:
                let bytes = arr.compactMap { ($0 as? NSNumber)?.intValue }
                if bytes.count == arr.count, !bytes.isEmpty, bytes.allSatisfy({ (0...255).contains($0) }) {
                    out[key] = bytes.map { String(format: "%02x", $0) }.joined()
                }
            default: continue
            }
        }
        return out
    }

    /// eslogger writes nanoseconds ("2026-11-24T10:00:01.250000000Z"), which ISO8601DateFormatter can't read.
    static func parseTime(_ s: String) -> Date? {
        let parts = s.dropLast(s.hasSuffix("Z") ? 1 : 0).split(separator: ".", maxSplits: 1)
        guard let base = parts.first, let whole = ISO8601DateFormatter().date(from: String(base) + "Z") else { return nil }
        let fraction = parts.count > 1 ? Double("0." + parts[1].prefix(9)) ?? 0 : 0
        return whole.addingTimeInterval(fraction)
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

    /// The program named is part of macOS (a shell, dscl, sudo...). It's never the thing to delete: what it was
    /// asked to run is the problem.
    public var isSystemProgram: Bool { processPath.map(Self.isSystemPath) ?? false }

    public static func isSystemPath(_ p: String) -> Bool {
        ["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/System/"].contains { p.hasPrefix($0) }
    }

    public static let systemProgramNote = "macOS's own program: don't delete it. What it was asked to run is the problem."

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
    /// Known-malware hashes. Non-Apple programs are hashed as they start (cached by path and change time). The
    /// background watch passes a source that picks up a newer signed feed without a restart.
    public var feedSource: HashFeedSource
    public var feed: HashFeed? { feedSource.current }
    let hashes = ExecHashCache()

    /// eslogger events the rules use. `open` is left out: it's far too noisy to watch live.
    public static let events = ["exec", "create", "rename", "deleteextattr", "btm_launch_item_add"] + moreEvents

    /// The events to ask this Mac's eslogger for: the original five always (all on macOS 13+), the newer ones only
    /// if `eslogger --list-events` lists them. An unknown name makes eslogger refuse to start, which would stop the
    /// whole watch on an older macOS.
    public static func supportedEvents(listOutput: String?) -> [String] {
        let base = Array(events.prefix(5))
        let known = Set((listOutput ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        guard !known.isEmpty else { return base }
        return base + moreEvents.filter(known.contains)
    }

    /// Rare but serious events (research/watch-events/RESEARCH.md): a few a day, so they cost next to nothing.
    public static let moreEvents = [
        "xp_malware_detected", "xp_malware_remediated", "tcc_modify", "profile_add", "od_create_user", "od_delete_user", "od_group_add",
        "od_modify_password", "gatekeeper_user_override", "remote_thread_create", "screensharing_attach", "openssh_login",
    ]

    public init(
        home: URL, signatures: SignatureChecking = GuardedSignatureChecker(), feed: HashFeed? = nil, feedSource: HashFeedSource? = nil
    ) {
        self.home = home
        self.signatures = signatures
        self.feedSource = feedSource ?? HashFeedSource(fixed: feed)
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
            // Arguments are only code when a shell or interpreter runs them, or when the tool is the attack itself
            // (dscl -authonly, xattr -d quarantine). `macx check "curl|sh"` or a commit message is just text.
            let tool = ((e.target?.path ?? e.args.first ?? "") as NSString).lastPathComponent
            let wanted: Set<CommandPattern>? = Self.interpreters.contains(tool) ? nil : Self.toolPatterns[tool] ?? []
            let code =
                Self.interpreters.contains(tool)
                ? e.args.map(ShellText.stripDataHeredocs).joined(separator: " ") : e.args.joined(separator: " ")
            let result = wanted == [] ? GuardResult.none : PasteGuard.check(code)
            for p in result.patterns.sorted(by: { $0.rawValue < $1.rawValue }) where wanted?.contains(p) ?? true {
                var detail = String(command.prefix(300))
                if !result.decoded.isEmpty { detail += "\n  decodes to: " + result.decoded.joined(separator: "\n  decodes to: ") }
                add(p.rawValue, p.severity, p.title, detail)
            }
            if let feed, let t = e.target, !t.isPlatform, let hash = hashes.hash(t.path), let name = try? feed.lookup(sha256: hash) {
                add("known-malware", .critical, "A known malware program started", "\(name)\n  SHA-256 \(hash)\n  \(t.path)")
            }
            if let t = e.target, t.isUnsignedThirdParty, let place = Self.hiddenOrTempPlace(t.path, home: h) {
                if Self.isBuildFolder(t.path) {
                    add("exec-from-hidden-or-temp", .low, "A program you built ran from a developer build folder", t.path)
                } else if place == .toolFolder {
                    add(
                        "exec-from-hidden-or-temp", .low,
                        "An unsigned program ran from inside a hidden folder in your home (developer tools such as ~/.rustup live there)",
                        t.path)
                } else {
                    add("exec-from-hidden-or-temp", .high, "An unsigned program started from a hidden or temporary folder", t.path)
                }
            }
            // A script run by its #! line: the program is the interpreter, so look at the script itself.
            if let s = e.script, let place = Self.hiddenOrTempPlace(s, home: h), place != .toolFolder, !Self.isBuildFolder(s),
                !Self.isInstallerSandbox(s)
            {
                add("exec-from-hidden-or-temp", .medium, "A script started from a hidden or temporary folder", s)
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
                // App updaters (Squirrel's ShipIt, Sparkle) clear the flag on the update they just verified. A signed
                // third-party program doing that is normal; xattr or an unsigned program doing it is the AMOS move.
                if let p = e.process, !p.isPlatform, !(p.teamID ?? "").isEmpty {
                    add(
                        "quarantine-removed", .low, "A signed app cleared the download flag (usually its updater installing an update)",
                        e.filePath)
                } else {
                    add(
                        "quarantine-removed", .high, "The download-safety (quarantine) flag was removed, so macOS won't check this file",
                        e.filePath)
                }
            }

        case "btm_launch_item_add":
            let what = e.executablePath ?? e.itemURL ?? "unknown item"
            add("new-background-item", .medium, "A new login or background item was registered", what, pid: e.instigator?.pid)
            if let exe = e.executablePath {
                let sig = signatures.check(exe)
                if sig.isWithoutDeveloper {
                    add(
                        "new-background-item-unsigned", .high, "The new background item runs a program that's \(sig.label)", exe,
                        pid: e.instigator?.pid)
                }
            }

        default:
            out += evaluateMore(e)
        }
        return out.sorted { $0.severity > $1.severity }
    }

    /// Programs whose arguments are code.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "tcsh", "csh", "fish", "python", "python3", "perl", "ruby", "node", "osascript", "env",
    ]

    static func isBuildFolder(_ path: String) -> Bool {
        ["/.build/", "/DerivedData/", "/Build/Products/"].contains { path.contains($0) }
    }

    /// Programs whose own arguments are the attack (no shell involved): which patterns to look for in them.
    static let toolPatterns: [String: Set<CommandPattern>] = {
        var t: [String: Set<CommandPattern>] = [
            "dscl": [.passwordCheck], "xattr": [.quarantineStrip], "security": [.keychainRead], "launchctl": [.launchctlSubmit],
        ]
        for tool in CommandPatterns.fileTools.split(separator: "|") { t[String(tool)] = [.keychainRead, .browserDataRead] }
        return t
    }()

    enum HiddenPlace: Equatable {
        /// /tmp, /Users/Shared, Downloads.
        case temp
        /// A hidden file or folder anywhere else: right in the home folder (~/.helper), in Application Support...
        case hidden
        /// Deep inside a hidden folder at the top of the home folder (~/.rustup/toolchains/.../bin/rustc), where
        /// developer tools install themselves.
        case toolFolder
    }

    static func hiddenOrTempPlace(_ path: String, home: String) -> HiddenPlace? {
        let temp = ["/tmp/", "/private/tmp/", "/private/var/tmp/", "/var/tmp/", "/Users/Shared/", "\(home)/Downloads/"]
        if temp.contains(where: { path.hasPrefix($0) }) { return .temp }
        let parts = path.split(separator: "/")
        guard parts.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) else { return nil }
        let homeParts = home.split(separator: "/")
        if path.hasPrefix(home + "/."), parts.count >= homeParts.count + 3, parts[homeParts.count].count > 1,
            !parts.dropFirst(homeParts.count + 1).contains(where: { $0.hasPrefix(".") })
        {
            return .toolFolder
        }
        return .hidden
    }

    static func isHiddenOrTemp(_ path: String, home: String) -> Bool { hiddenOrTempPlace(path, home: home) != nil }

    /// macOS Installer runs package scripts from its own sandbox in /private/tmp.
    static func isInstallerSandbox(_ path: String) -> Bool {
        path.hasPrefix("/private/tmp/PKInstallSandbox.") || path.hasPrefix("/tmp/PKInstallSandbox.")
            || path.hasPrefix("/Library/InstallerSandboxes/")
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
