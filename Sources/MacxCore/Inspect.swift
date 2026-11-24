import Foundation

// MARK: - Finding downloads that get run

public struct DownloadRun: Sendable, Equatable {
    public enum Form: String, Sendable {
        /// `curl URL | sh`
        case pipe
        /// `bash <(curl URL)`
        case processSubstitution
        /// `bash -c "$(curl URL)"`, `eval "$(curl URL)"`
        case commandSubstitution
        /// `curl -o f URL && sh f`, `curl -O URL; ./f`
        case downloadThenRun
    }

    public var url: String
    /// The shell or interpreter that runs it; nil when the downloaded file is run directly.
    public var interpreter: String?
    public var arguments: [String]
    public var form: Form

    public init(url: String, interpreter: String?, arguments: [String], form: Form) {
        self.url = url
        self.interpreter = interpreter
        self.arguments = arguments
        self.form = form
    }
}

public enum DownloadRuns {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "perl", "ruby", "osascript", "node"]
    static let downloaders: Set<String> = ["curl", "wget"]

    /// Every download in the text that is then run, after undoing simple disguises. Base64 payloads and
    /// `echo "..." | sh` are looked inside too.
    public static func find(in text: String) -> [DownloadRun] {
        var seen: [DownloadRun] = []
        func add(_ r: DownloadRun) { if !seen.contains(r) { seen.append(r) } }
        var queue = [(ShellNormalizer.normalize(text), 0)]
        while let (current, depth) = queue.first {
            queue.removeFirst()
            findDirect(in: current).forEach(add)
            guard depth < 3 else { continue }
            for d in CommandPatterns.decodedPayloads(in: current) { queue.append((ShellNormalizer.normalize(d), depth + 1)) }
            for inner in echoedIntoShell(current) { queue.append((ShellNormalizer.normalize(inner), depth + 1)) }
        }
        return seen
    }

    static func base(_ word: String) -> String { (word as NSString).lastPathComponent }
    static func url(in words: [String]) -> String? {
        words.first { $0.range(of: #"^(https?|ftp)://"#, options: .regularExpression) != nil }
    }

    static func findDirect(in text: String) -> [DownloadRun] {
        var out: [DownloadRun] = []
        let commands = ShellWords.commands(text)
        var downloadedFiles: [(file: String, url: String)] = []

        for command in commands {
            // bash <(curl URL)   and   bash -c "$(curl URL)" / eval "$(curl URL)"
            let words = ShellWords.split(command)
            if let first = words.first {
                let tool = base(first)
                if shells.contains(tool) || tool == "source" || tool == "." || tool == "eval" {
                    if let m = firstMatch(#"<\(\s*(?:\S*/)?(?:curl|wget)\b([^)]*)\)"#, in: command),
                        let u = url(in: ShellWords.split(m))
                    {
                        out.append(DownloadRun(url: u, interpreter: tool, arguments: [], form: .processSubstitution))
                    } else if let m = firstMatch(#"\$\(\s*(?:\S*/)?(?:curl|wget)\b([^)]*)\)"#, in: command),
                        let u = url(in: ShellWords.split(m))
                    {
                        out.append(DownloadRun(url: u, interpreter: tool == "eval" ? nil : tool, arguments: [], form: .commandSubstitution))
                    }
                }
            }

            // curl URL | sh
            let stages = ShellWords.pipeline(command).map(ShellWords.split)
            if stages.count > 1 {
                for (i, stage) in stages.enumerated() {
                    guard let tool = stage.first.map(base), downloaders.contains(tool), let u = url(in: stage), toStdout(stage, tool) else {
                        continue
                    }
                    if let runner = stages[(i + 1)...].first(where: { $0.first.map { shells.contains(base($0)) } ?? false }) {
                        out.append(DownloadRun(url: u, interpreter: base(runner[0]), arguments: scriptArguments(runner), form: .pipe))
                    }
                }
            }

            // Two steps: a download to a file, then that file run later in the same paste.
            if let first = words.first, downloaders.contains(base(first)), let u = url(in: words), let f = outputFile(words, base(first), u)
            {
                downloadedFiles.append((f, u))
                continue
            }
            if let first = words.first {
                for (file, u) in downloadedFiles {
                    let matchesFile = { (w: String) in w == file || w == "./" + file || base(w) == base(file) && w.hasSuffix(file) }
                    if shells.contains(base(first)) || first == "source" || first == ".", words.count > 1, matchesFile(words[1]) {
                        out.append(
                            DownloadRun(url: u, interpreter: base(first), arguments: Array(words.dropFirst(2)), form: .downloadThenRun))
                    } else if matchesFile(first) {
                        out.append(DownloadRun(url: u, interpreter: nil, arguments: Array(words.dropFirst()), form: .downloadThenRun))
                    }
                }
            }
        }
        return out
    }

    /// The downloader writes to standard output (so piping it somewhere means running it).
    static func toStdout(_ words: [String], _ tool: String) -> Bool {
        if tool == "curl" { return !words.contains { $0 == "-o" || $0 == "--output" || $0 == "-O" || $0 == "--remote-name" } }
        // wget writes to a file unless told -O - / -qO-.
        return words.contains { $0 == "-O-" || $0.hasSuffix("O-") } || zip(words, words.dropFirst()).contains { $0 == "-O" && $1 == "-" }
    }

    static func outputFile(_ words: [String], _ tool: String, _ url: String) -> String? {
        let fromURL = URL(string: url)?.lastPathComponent
        for (a, b) in zip(words, words.dropFirst()) where (a == "-o" || a == "--output" || (tool == "wget" && a == "-O")) && b != "-" {
            return b
        }
        if tool == "curl", words.contains(where: { $0 == "-O" || $0 == "--remote-name" }) { return fromURL }
        if tool == "wget", !toStdout(words, tool) { return fromURL }
        return nil
    }

    /// Arguments passed to a script read from stdin: what follows `-s --`, `-s` or `--`.
    static func scriptArguments(_ runner: [String]) -> [String] {
        if let dd = runner.firstIndex(of: "--") { return Array(runner[(dd + 1)...]) }
        return []
    }

    /// `echo "X" | sh` runs X.
    static func echoedIntoShell(_ text: String) -> [String] {
        var out: [String] = []
        for command in ShellWords.commands(text) {
            let stages = ShellWords.pipeline(command).map(ShellWords.split)
            guard stages.count >= 2, let first = stages.first, first.first == "echo" || first.first == "printf",
                let last = stages.last?.first, shells.contains(base(last))
            else { continue }
            out.append(first.dropFirst().filter { !$0.hasPrefix("-") }.joined(separator: " "))
        }
        return out
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }
}

// MARK: - Inspecting a downloaded script

public enum FetchedKind: String, Sendable {
    case script, binary, archive, webPage, empty, other
}

public struct Inspection: Sendable {
    public var url: URL
    public var finalURL: URL
    public var kind: FetchedKind
    public var bytes: Int
    public var sha256: String
    /// What the script does, from its own text.
    public var behaviours: [CheckFinding]
    /// Facts about where it came from and how it's written.
    public var facts: [CheckFinding]
    /// What it does that can't be read from the text (eval of a variable, a computed link, a script it
    /// writes and runs, a program it downloads). Never treated as safe.
    public var unknowns: [CheckFinding] = []
    public var nestedDownloads: [DownloadRun]
    /// Inspections of the nested downloads (one level).
    public var nested: [Inspection] = []

    public var findings: [CheckFinding] { behaviours + facts + unknowns + nested.flatMap(\.findings) }
    public var verdict: Verdict { Verdict.from(findings) }
}

public enum ScriptInspector {
    /// What a script does, matched on its text. Each is a behaviour, not a guess about who wrote it.
    static let behaviourRules: [(id: String, severity: Severity, title: String, pattern: String)] = [
        ("password-prompt", .critical, "Shows a script-made password box", #"osascript\b.*display dialog.*hidden answer"#),
        (
            "password-check", .critical, "Checks your password with dscl (stealers do this to test a stolen password)",
            #"\bdscl\s+\.\s+-authonly\b"#
        ),
        (
            "keychain-read", .high, "Reads passwords from the keychain",
            #"\bsecurity\s+(?:find-(?:generic|internet)-password|dump-keychain|export)\b|login\.keychain"#
        ),
        (
            "browser-data", .high, "Touches browser password or cookie files",
            #"Login\\? Data|Web\\? Data|Local\\? State|\bCookies\b|key4\.db|logins\.json|cookies\.sqlite"#
        ),
        ("wallet-data", .high, "Touches crypto wallet files", #"(?i)\b(?:wallet\.dat|Exodus/exodus\.wallet|Electrum/wallets)\b"#),
        (
            "uploads-files", .high, "Uploads files to a server",
            #"\bcurl\b[^\n]*(?:\s-F\s|\s--form\s|\s-T\s|--upload-file|--data-binary\s+@|\s-d\s+@)"#
        ),
        (
            "closes-terminal", .high, "Closes Terminal (hides what it did)",
            #"\bkillall\s+Terminal\b|tell application "Terminal" to (?:quit|close)"#
        ),
        (
            "launch-item", .medium, "Sets itself to start automatically (launch daemon or agent)",
            #"/Library/Launch(?:Daemons|Agents)/|\blaunchctl\s+(?:load|bootstrap|enable)\b"#
        ),
        // Apple's own launch items and folders never come from a downloaded script: these are the AMOS disguise.
        (
            "fake-apple-launch-item", .high, "Writes an Apple-named launch item (Apple's own are never installed by scripts)",
            #"/Library/Launch(?:Daemons|Agents)/com\.apple\."#
        ),
        (
            "fake-apple-folder", .high, "Creates a hidden Apple-named folder in Application Support (AMOS hides here)",
            #"Application Support/\.com\.apple\."#
        ),
        ("hidden-folder", .medium, "Writes into a hidden folder in Application Support", #"Application Support/\.[A-Za-z0-9]"#),
        (
            "quarantine-strip", .high, "Removes macOS's download-safety (quarantine) flag",
            #"\bxattr\b[^\n]*(?:com\.apple\.quarantine|\s-[a-z]*c[a-z]*r|\s-[a-z]*r[a-z]*c)"#
        ),
        ("cron", .medium, "Adds a cron job", #"\bcrontab\b"#),
        ("runs-in-background", .low, "Keeps running in the background after it finishes", #"\bnohup\b|\bdisown\b"#),
        ("asks-for-admin", .low, "Asks for admin rights (sudo)", #"\bsudo\b"#),
    ]

    static let compiledRules: [(String, Severity, String, NSRegularExpression)] = behaviourRules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern)).map { (r.id, r.severity, r.title, $0) }
    }

    public static func inspect(_ data: Data, url: URL, finalURL: URL, knownHosts: Set<String>) -> Inspection {
        let kind = classify(data)
        var behaviours: [CheckFinding] = []
        var facts: [CheckFinding] = []
        var unknowns: [CheckFinding] = []
        var nested: [DownloadRun] = []

        if kind == .script {
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (id, sev, title, re) in compiledRules {
                if let n = lines.firstIndex(where: { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                    behaviours.append(
                        CheckFinding(
                            rule: id, severity: sev, title: title,
                            detail: "line \(n + 1): \(lines[n].trimmingCharacters(in: .whitespaces).prefix(200))"))
                }
            }
            // A VM check often spans lines (query on one, comparison on the next), so it's matched on the whole text.
            if CommandPatterns.match(text).contains(.vmCheck) {
                let p = CommandPattern.vmCheck
                let n = lines.firstIndex { $0.range(of: #"system_profiler|ioreg|hw\.model"#, options: .regularExpression) != nil } ?? 0
                behaviours.append(
                    CheckFinding(
                        rule: p.rawValue, severity: p.severity, title: p.title,
                        detail: "line \(n + 1): \(lines[n].trimmingCharacters(in: .whitespaces).prefix(200))"))
            }
            nested = lines.flatMap { DownloadRuns.find(in: $0) }
            if !nested.isEmpty {
                behaviours.append(
                    CheckFinding(
                        rule: "downloads-and-runs-more", severity: .medium, title: "Downloads more code and runs it",
                        detail: nested.map(\.url).joined(separator: ", ")))
            }
            let decoded = lines.flatMap { CommandPatterns.decodedPayloads(in: $0) }
            if !decoded.isEmpty {
                behaviours.append(
                    CheckFinding(
                        rule: "decodes-hidden-code", severity: .high, title: "Decodes hidden (base64) code",
                        detail: decoded.map { String($0.prefix(160)) }.joined(separator: "\n")))
            }
            // Several sensitive steps together are what a stealer does; any one of them alone can be ordinary.
            let ids = Set(behaviours.map(\.rule))
            let credentials = ids.intersection(["browser-data", "keychain-read", "wallet-data"])
            if !credentials.isEmpty, ids.contains("uploads-files") {
                behaviours.insert(
                    CheckFinding(
                        rule: "stealer-pattern", severity: .critical, title: "Collects passwords or browser data and uploads them",
                        detail: credentials.sorted().joined(separator: " + ") + " + uploads-files"), at: 0)
            } else if ids.contains("password-prompt"), ids.contains("password-check") || !credentials.isEmpty {
                let parts = ["password-prompt"] + (ids.contains("password-check") ? ["password-check"] : []) + credentials.sorted()
                behaviours.insert(
                    CheckFinding(
                        rule: "stealer-pattern", severity: .critical, title: "Asks for your password and then uses it",
                        detail: parts.joined(separator: " + ")), at: 0)
            }
            unknowns = Self.unknowns(in: lines)

            if text.range(of: #"[A-Za-z0-9+/]{200,}={0,2}"#, options: .regularExpression) != nil {
                facts.append(
                    CheckFinding(rule: "encoded-blob", severity: .medium, title: "Contains a long encoded block (hard to read on purpose)"))
            }
            if lines.contains(where: { $0.count > 5000 }) {
                facts.append(CheckFinding(rule: "very-long-line", severity: .low, title: "Has a line over 5,000 characters"))
            }
        }

        switch kind {
        case .binary:
            facts.append(
                CheckFinding(rule: "serves-a-program", severity: .high, title: "The link gives a program, not a script you can read"))
        case .archive:
            facts.append(
                CheckFinding(rule: "serves-an-archive", severity: .medium, title: "The link gives a compressed archive, not a script"))
        case .webPage:
            facts.append(CheckFinding(rule: "serves-a-web-page", severity: .info, title: "The link gives a web page, not a script"))
        case .empty:
            facts.append(
                CheckFinding(
                    rule: "empty", severity: .medium, title: "The link gave nothing (it may only serve the real script to some visitors)"))
        default: break
        }

        for u in Set([url, finalURL]) {
            if let host = u.host, isIPAddress(host) {
                facts.append(
                    CheckFinding(
                        rule: "ip-address-host", severity: .medium, title: "Downloads from a bare IP address, not a domain",
                        detail: host))
                break
            }
        }
        if finalURL.scheme == "http" || url.scheme == "http" {
            facts.append(
                CheckFinding(rule: "plain-http", severity: .medium, title: "Uses plain http, so anyone on the network could change it"))
        }
        if let a = url.host, let b = finalURL.host, a.lowercased() != b.lowercased() {
            facts.append(CheckFinding(rule: "redirected", severity: .low, title: "Redirects to another site", detail: "\(a) → \(b)"))
        }
        if let host = finalURL.host?.lowercased(), !knownHosts.contains(host) {
            facts.append(
                CheckFinding(rule: "new-host", severity: .low, title: "You've never used this site in your shell before", detail: host))
        }

        return Inspection(
            url: url, finalURL: finalURL, kind: kind, bytes: data.count, sha256: sha256(data), behaviours: behaviours,
            facts: facts, unknowns: unknowns, nestedDownloads: nested)
    }

    static let shellNames = #"(?:ba|z|k|da)?sh"#
    /// `eval "$x"` / `sh -c "$x"`: a variable whose content isn't visible. `eval "$(brew shellenv)"` runs a
    /// visible command instead, so it doesn't count.
    static let evalOfVariable = #"\beval\s+["']?\$\{?[A-Za-z_]|\b(?:ba|z|k|da)?sh\s+-c\s+["']?\$\{?[A-Za-z_]"#

    /// Code whose effect can't be read from the text. Each is reported as unknown (medium), so the
    /// verdict can't be "ok" while part of the script is unseen.
    static func unknowns(in lines: [String]) -> [CheckFinding] {
        var out: [CheckFinding] = []
        func add(_ rule: String, _ title: String, _ n: Int) {
            guard !out.contains(where: { $0.rule == rule }) else { return }
            out.append(
                CheckFinding(
                    rule: rule, severity: .medium, title: title,
                    detail: "line \(n + 1): \(lines[n].trimmingCharacters(in: .whitespaces).prefix(200))"))
        }
        func has(_ line: String, _ pattern: String) -> Bool { line.range(of: pattern, options: .regularExpression) != nil }

        for (n, raw) in lines.enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { continue }
            if has(l, evalOfVariable) {
                add("runs-unresolved-code", "Runs code held in a variable, so what it runs can't be read here", n)
            }
            let downloads = has(l, #"\b(?:curl|wget)\b"#)
            let computedURL =
                has(l, #"(?:https?|ftp)://[^\s"']*\$"#) || (!has(l, #"(?:https?|ftp)://"#) && has(l, #"\$\{?[A-Za-z_]"#))
            let runsOrSaves = has(l, #"\|\s*(?:sudo\s+)?"# + shellNames + #"\b|\s-o\s|\s-O\b"#)
            if downloads, computedURL, runsOrSaves {
                add("computed-download", "Downloads from a link worked out while it runs, so it can't be checked first", n)
            }
        }

        // A program downloaded and then run directly can't be read as text.
        let text = lines.joined(separator: "\n")
        if let n = lines.firstIndex(where: { has($0, #"\b(?:curl|wget)\b"#) }),
            DownloadRuns.findDirect(in: text).contains(where: { $0.form == .downloadThenRun && $0.interpreter == nil })
        {
            add("downloads-program-to-run", "Downloads a program and runs it (the program itself can't be read as text)", n)
        }

        // A script written from changing content and then run.
        if let re = try? NSRegularExpression(pattern: #"\b(?:echo|printf|cat)\b[^\n]*\$[^\n]*>\s*([^\s;&|]+)"#) {
            for (n, line) in lines.enumerated() {
                guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                    let r = Range(m.range(at: 1), in: line)
                else { continue }
                let file = String(line[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let runsIt = lines[(n + 1)...].contains { later in
                    let w = ShellWords.split(later)
                    guard let first = w.first else { return false }
                    let viaShell = DownloadRuns.shells.contains((first as NSString).lastPathComponent) || first == "source" || first == "."
                    let target = viaShell ? (w.count > 1 ? w[1] : "") : first
                    return target == file
                }
                if runsIt { add("runs-generated-script", "Writes a script from changing content and then runs it", n) }
            }
        }
        return out
    }

    static func classify(_ data: Data) -> FetchedKind {
        if data.isEmpty { return .empty }
        let head = [UInt8](data.prefix(512))
        // Any Mach-O magic (thin 32/64-bit either byte order, or universal) means a program.
        let magics: [[UInt8]] = [
            [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF],
        ]
        if magics.contains(where: { head.starts(with: $0) }) { return .binary }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x1F, 0x8B]) || head.starts(with: Array("xar!".utf8)) {
            return .archive
        }
        guard String(data: data.prefix(4096), encoding: .utf8) != nil || String(data: data, encoding: .utf8) != nil, !head.contains(0)
        else {
            return .other
        }
        let start = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") { return .webPage }
        return .script
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1
    }

    /// Hosts that appear in earlier shell commands: a fact about you, used to say "new site".
    public static func hosts(inHistory commands: [String]) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"(?:https?|ftp)://([A-Za-z0-9.-]+)"#) else { return [] }
        var out: Set<String> = []
        for c in commands {
            for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
                if let r = Range(m.range(at: 1), in: c) { out.insert(c[r].lowercased()) }
            }
        }
        return out
    }
}

// MARK: - Fetching

public struct FetchResult: Sendable {
    public var finalURL: URL
    public var status: Int
    public var data: Data

    public init(finalURL: URL, status: Int, data: Data) {
        self.finalURL = finalURL
        self.status = status
        self.data = data
    }
}

public enum FetchError: Error, Equatable, CustomStringConvertible {
    case status(Int)
    case tooBig(Int)
    case network(String)

    public var description: String {
        switch self {
        case .status(let s): "the server answered HTTP \(s)"
        case .tooBig(let n): "it's larger than \(n / 1_000_000) MB"
        case .network(let m): m
        }
    }
}

public protocol ScriptFetching: Sendable {
    func fetch(_ url: URL) throws -> FetchResult
}

/// Downloads like curl would (same kind of User-Agent, no cookies), so the server sends what the
/// pasted command would have received. Nothing is run.
public struct URLSessionFetcher: ScriptFetching {
    public var maxBytes = 5_000_000
    public var userAgent: String

    public init(userAgent: String = URLSessionFetcher.curlUserAgent()) { self.userAgent = userAgent }

    public static func curlUserAgent() -> String {
        if let out = try? ProcessRunner().run("/usr/bin/curl", ["--version"]),
            let v = out.split(separator: " ").dropFirst().first
        {
            return "curl/\(v)"
        }
        return "curl/8"
    }

    public func fetch(_ url: URL) throws -> FetchResult {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")

        nonisolated(unsafe) var result: Result<(Data, URLResponse), Error> = .failure(FetchError.network("no answer"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, error in
            if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(FetchError.network(error?.localizedDescription ?? "no answer"))
            }
            done.signal()
        }.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        let (data, response) = try result.get()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw FetchError.status(status) }
        guard data.count <= maxBytes else { throw FetchError.tooBig(maxBytes) }
        return FetchResult(finalURL: response.url ?? url, status: status, data: data)
    }
}

// MARK: - Inspecting a paste

public struct InspectedRun: Sendable {
    public var run: DownloadRun
    public var inspection: Inspection?
    /// The exact bytes that were inspected. Running this (not the link again) means the server can't swap it.
    public var savedCopy: URL?
    public var error: String?
}

public struct PasteReport: Sendable {
    public var command: String
    public var guardResult: GuardResult
    public var runs: [InspectedRun]

    /// The delivery itself (`curl | sh`) has now been looked inside, so it no longer counts on its own;
    /// hiding the command in base64 and every other pattern still do. A link that couldn't be read counts as dangerous.
    public var findings: [CheckFinding] {
        var out = guardResult.patterns.filter { $0 != .downloadToShell }.map {
            CheckFinding(rule: $0.rawValue, severity: $0.severity, title: $0.title)
        }
        for r in runs {
            if let e = r.error {
                out.append(
                    CheckFinding(
                        rule: "unreadable-download", severity: .high, title: "Couldn't download it to check (\(e))",
                        detail: r.run.url))
            }
            out += r.inspection?.findings ?? []
        }
        return out
    }

    public var verdict: Verdict { Verdict.from(findings) }
}

public struct PasteInspector: Sendable {
    var fetcher: ScriptFetching
    var saveDir: URL
    var knownHosts: Set<String>

    public init(fetcher: ScriptFetching = URLSessionFetcher(), saveDir: URL = PasteInspector.defaultSaveDir, knownHosts: Set<String>) {
        self.fetcher = fetcher
        self.saveDir = saveDir
        self.knownHosts = knownHosts
    }

    public static var defaultSaveDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/Inspected")
    }

    public func inspect(command: String) -> PasteReport {
        let result = PasteGuard.check(command)
        let runs = DownloadRuns.find(in: command).map { run -> InspectedRun in
            guard let url = URL(string: run.url) else { return InspectedRun(run: run, error: "not a valid link") }
            do {
                let fetched = try fetcher.fetch(url)
                var inspection = ScriptInspector.inspect(fetched.data, url: url, finalURL: fetched.finalURL, knownHosts: knownHosts)
                inspection.nested = inspection.nestedDownloads.prefix(5).compactMap { nestedRun in
                    guard let u = URL(string: nestedRun.url), let f = try? fetcher.fetch(u) else { return nil }
                    return ScriptInspector.inspect(f.data, url: u, finalURL: f.finalURL, knownHosts: knownHosts)
                }
                let saved = try? save(fetched.data, sha: inspection.sha256, name: url.lastPathComponent)
                return InspectedRun(run: run, inspection: inspection, savedCopy: saved)
            } catch {
                return InspectedRun(run: run, error: (error as? FetchError)?.description ?? error.localizedDescription)
            }
        }
        return PasteReport(command: command, guardResult: result, runs: runs)
    }

    /// Owner-only and not executable, so nothing runs it by accident.
    func save(_ data: Data, sha: String, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let safeName = name.isEmpty || name == "/" ? "script" : name.replacingOccurrences(of: "/", with: "_")
        let file = saveDir.appendingPathComponent("\(sha.prefix(12))-\(safeName)")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}

// MARK: - Running exactly what was inspected

public enum VerifiedCopy {
    public struct Mismatch: Error, CustomStringConvertible {
        public var expected: String
        public var found: String
        public var description: String {
            "the saved copy changed after it was inspected (expected SHA-256 \(expected.prefix(12))…, found \(found.prefix(12))…)"
        }
    }

    /// Reads the saved copy and checks it still has the inspected SHA-256. Callers run these bytes,
    /// never the file again, so nothing can swap it between the check and the run.
    public static func bytes(at file: URL, sha256 expected: String) throws -> Data {
        let data = try Data(contentsOf: file)
        let found = sha256(data)
        guard found == expected else { throw Mismatch(expected: expected, found: found) }
        return data
    }

    /// Arguments that make an interpreter read its script from standard input, as `curl … | sh` does.
    /// Nil when the interpreter has no such mode.
    public static func stdinArguments(for interpreter: String, scriptArgs: [String]) -> [String]? {
        switch interpreter {
        case "sh", "bash", "zsh", "dash", "ksh":
            return scriptArgs.isEmpty ? ["-s"] : ["-s", "--"] + scriptArgs
        case "python", "python3", "perl", "ruby", "node":
            return ["-"] + scriptArgs
        default:
            return nil
        }
    }
}
