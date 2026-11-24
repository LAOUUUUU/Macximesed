import Foundation

// The detonation chamber's host side: everything that happens on the real Mac before and after a sample runs
// in the throwaway virtual machine. Spec: specs/detonation-chamber.md.

/// The guest's event log, read as untrusted data: size and line caps, junk skipped, nothing in it followed.
public enum ChamberLog {
    public static let maxBytes = 20_000_000
    public static let maxLineBytes = 65_536
    public static let maxLines = 200_000

    public struct Parsed: Sendable {
        public var events: [ESEvent]
        public var skipped: Int
        public var truncated: Bool
    }

    public static func parse(_ data: Data, maxBytes: Int = maxBytes) -> Parsed {
        let truncated = data.count > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data
        var events: [ESEvent] = []
        var skipped = 0
        var lines = 0
        for raw in slice.split(separator: 0x0A, omittingEmptySubsequences: true) {
            lines += 1
            if lines > maxLines {
                return Parsed(events: events, skipped: skipped, truncated: true)
            }
            guard raw.count <= maxLineBytes, let e = ESEvent.parse(String(decoding: raw, as: UTF8.self)) else {
                skipped += 1
                continue
            }
            events.append(e)
        }
        return Parsed(events: events, skipped: skipped, truncated: truncated)
    }
}

public enum ChamberVerdict: String, Sendable, Codable {
    case dangerous, caution, nothingSeen

    public var label: String {
        switch self {
        case .dangerous: "DON'T OPEN THIS"
        case .caution: "Be careful"
        case .nothingSeen: "Nothing seen"
        }
    }
}

public struct ChamberReport: Sendable {
    public var verdict: ChamberVerdict
    public var alerts: [WatchAlert]
    public var summary: String
    public var skipped: Int
    public var truncated: Bool

    public init(verdict: ChamberVerdict, alerts: [WatchAlert], summary: String, skipped: Int, truncated: Bool) {
        self.verdict = verdict
        self.alerts = alerts
        self.summary = summary
        self.skipped = skipped
        self.truncated = truncated
    }
}

/// Paths in the guest aren't files on this Mac, so nothing is looked up for them.
struct GuestSignatures: SignatureChecking {
    func check(_ path: String) -> SignatureInfo { .unreadable }
}

/// Judges what the sample did in the guest: the live-watch rules plus chamber rules, counting only the sample's
/// own process tree (macOS's daemons open keychains and write files all the time).
public struct ChamberJudge: Sendable {
    public var guestHome: URL
    public var quitWindow: TimeInterval

    public init(guestHome: URL, quitWindow: TimeInterval = 10) {
        self.guestHome = guestHome
        self.quitWindow = quitWindow
    }

    /// From the guest's eslogger log (JSON lines).
    public func judge(log: Data, samplePID: Int?) -> ChamberReport {
        let parsed = ChamberLog.parse(log)
        return judge(events: parsed.events, samplePID: samplePID, skipped: parsed.skipped, truncated: parsed.truncated)
    }

    /// From events already parsed (the light chamber's strace log goes through `StraceLog`).
    public func judge(events: [ESEvent], samplePID: Int?, skipped: Int = 0, truncated: Bool = false) -> ChamberReport {
        let parsed = ChamberLog.Parsed(events: events, skipped: skipped, truncated: truncated)
        let rules = WatchRules(home: guestHome, signatures: GuestSignatures(), feed: nil)
        var tree: Set<Int> = samplePID.map { [$0] } ?? []
        func inTree(_ pid: Int?) -> Bool { samplePID == nil || pid.map(tree.contains) == true }

        var alerts: [WatchAlert] = []
        var seen: Set<String> = []
        func keep(_ a: WatchAlert) {
            // One line per kind of read (a copied "Login Data" is the same theft); other rules per detail.
            let key = a.rule.hasPrefix("reads-") ? a.rule : "\(a.rule)|\(a.detail ?? "")"
            if seen.insert(key).inserted { alerts.append(a) }
        }
        var vmCheckAt: Date?
        var pipeQuery: [Int: (Date, String)] = [:]
        var pipeFilter: [Int: (Date, String)] = [:]
        var quitAfterVMCheck = false

        for e in parsed.events {
            // Children join the tree as they start.
            if e.kind == "exec", let t = e.target, let ppid = t.ppid, let pid = t.pid, tree.contains(ppid) || tree.contains(pid) {
                tree.insert(pid)
            }
            let actor = e.kind == "exec" ? (e.target ?? e.process) : e.process
            guard inTree(actor?.pid) || inTree(e.process?.pid) else { continue }

            for a in rules.evaluate(e) {
                keep(a)
                if a.rule == CommandPattern.vmCheck.rawValue, vmCheckAt == nil { vmCheckAt = e.time ?? .distantPast }
            }
            for a in Self.fileRules(e, home: guestHome.path) { keep(a) }
            // A VM check split across a pipe: a hardware query and a VM-name filter started by the same shell.
            if e.kind == "exec", let t = e.target, let parent = t.ppid {
                let tool = (t.path as NSString).lastPathComponent
                let line = e.args.joined(separator: " ")
                let isQuery = ["system_profiler", "ioreg"].contains(tool) || (tool == "sysctl" && line.contains("hw.model"))
                // Next to a hardware query, a bare "virtual" means the same.
                let namesVM =
                    line.range(of: CommandPatterns.vmNames + #"|\bvirtual"#, options: [.regularExpression, .caseInsensitive]) != nil
                let when = e.time ?? .distantPast
                if isQuery { pipeQuery[parent] = (when, line) }
                if namesVM, !isQuery { pipeFilter[parent] = (when, line) }
                if let q = pipeQuery[parent], let f = pipeFilter[parent], abs(q.0.timeIntervalSince(f.0)) <= 5 {
                    let p = CommandPattern.vmCheck
                    keep(
                        WatchAlert(
                            rule: p.rawValue, severity: p.severity, title: p.title, detail: "\(q.1) | \(f.1)", pid: t.pid,
                            processPath: t.path))
                    if vmCheckAt == nil { vmCheckAt = when }
                    pipeQuery[parent] = nil
                    pipeFilter[parent] = nil
                }
            }
            if e.kind == "exit", e.process?.pid == samplePID, let checked = vmCheckAt {
                let gap = (e.time ?? .distantFuture).timeIntervalSince(checked)
                if gap >= 0, gap <= quitWindow { quitAfterVMCheck = true }
            }
        }
        if quitAfterVMCheck {
            keep(
                WatchAlert(
                    rule: "vm-check-then-quit", severity: .high,
                    title: "Checked for a virtual machine and quit (it may hide what it does on a real Mac)", detail: nil,
                    pid: samplePID, processPath: nil))
        }
        alerts.sort { $0.severity > $1.severity }

        let highs = Set(alerts.filter { $0.severity == .high }.map(\.rule))
        let verdict: ChamberVerdict =
            alerts.contains { $0.severity == .critical } || highs.count >= 2
            ? .dangerous : alerts.contains { $0.severity >= .medium } ? .caution : .nothingSeen
        var summary: String
        switch verdict {
        case .dangerous: summary = "It did what malware does: " + alerts.prefix(4).map(\.title).joined(separator: "; ") + "."
        case .caution: summary = "It did something worth a closer look: " + alerts.prefix(4).map(\.title).joined(separator: "; ") + "."
        case .nothingSeen:
            summary =
                "Nothing suspicious happened in the chamber. That's not the same as safe: malware can wait longer than the run, wait for a click or a password, or notice it's in a virtual machine and stay quiet."
        }
        if quitAfterVMCheck {
            summary += " It checked whether it was in a virtual machine and then quit, so it may behave differently on your Mac."
        }
        if parsed.truncated || parsed.skipped > 0 {
            summary += " (\(parsed.skipped) unreadable log lines skipped\(parsed.truncated ? ", log cut off at the size limit" : "").)"
        }
        return ChamberReport(verdict: verdict, alerts: alerts, summary: summary, skipped: parsed.skipped, truncated: parsed.truncated)
    }

    /// What a stealer reads: keychains, browser password and cookie stores, wallets.
    static func fileRules(_ e: ESEvent, home: String) -> [WatchAlert] {
        let pid = e.process?.pid
        let who = e.process?.path
        if e.kind == "connect", let endpoint = e.filePath {
            // The chamber has no network, so this always fails; the attempt shows where it wanted to send things.
            return [
                WatchAlert(
                    rule: "network-attempt", severity: .medium, title: "Tried to reach the internet", detail: endpoint, pid: pid,
                    processPath: who)
            ]
        }
        if e.kind == "exec", let t = e.target, ["curl", "wget"].contains((t.path as NSString).lastPathComponent),
            let url = e.args.dropFirst().first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("ftp://") })
        {
            return [
                WatchAlert(
                    rule: "network-attempt", severity: .medium, title: "Tried to reach the internet", detail: url, pid: t.pid,
                    processPath: t.path)
            ]
        }
        guard e.kind == "open", let path = e.filePath else { return [] }
        func alert(_ rule: String, _ sev: Severity, _ title: String) -> [WatchAlert] {
            [WatchAlert(rule: rule, severity: sev, title: title, detail: path, pid: pid, processPath: who)]
        }
        let name = (path as NSString).lastPathComponent
        if path.contains("/Library/Keychains/"), name.hasSuffix(".keychain-db") || name.hasSuffix(".keychain") {
            return alert("reads-keychain", .critical, "Read a keychain (where your saved passwords live)")
        }
        let browserFiles: Set<String> = ["Login Data", "Web Data", "Cookies", "Local State", "key4.db", "logins.json", "cookies.sqlite"]
        if browserFiles.contains(name) || name == "Cookies.binarycookies" {
            return alert("reads-browser-data", .high, "Read browser passwords or cookies")
        }
        let walletMarks = ["/exodus.wallet/", "/Electrum/wallets/", "/Ledger Live/", "/atomic/Local Storage/", "/Coinomi/wallets/"]
        if name == "wallet.dat" || walletMarks.contains(where: path.contains) {
            return alert("reads-wallet", .high, "Read crypto wallet files")
        }
        return []
    }
}

/// The exact file that will be run, pinned by SHA-256 when the run is asked for.
public struct ChamberSample: Sendable {
    public enum Problem: Error, Equatable { case changed, unreadable }

    public let url: URL
    public let sha256: String
    public let bytes: Int

    public init(pinning url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { throw Problem.unreadable }
        self.url = url
        self.sha256 = MacxCore.sha256(data)
        self.bytes = data.count
    }

    public func verifyUnchanged() throws {
        guard let data = try? Data(contentsOf: url) else { throw Problem.unreadable }
        guard MacxCore.sha256(data) == sha256 else { throw Problem.changed }
    }
}

/// When the static checks send a file on to the chamber: a script that reading couldn't settle (*Be careful* or
/// *partly unknown*). A dangerous one needs no run to decide, a clean one has nothing more to show, and apps and
/// programs keep the static checks. One rule for `macx check` and `macx guard inspect`.
public enum ChamberHint {
    public static func applies(isScript: Bool, verdict: Verdict) -> Bool {
        isScript && (verdict == .caution || verdict == .partlyUnknown)
    }

    /// The line both commands print, with the path quoted when the shell needs it, so it can be pasted back.
    public static func line(path: String) -> String {
        "See what it actually does, safely: macx chamber run \(shellWord(path))"
    }

    static func shellWord(_ s: String) -> String {
        let bare = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(bare.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Puts a sample the chamber judged bad into an incident case and the undo store. Nothing is deleted.
public struct ChamberQuarantine: Sendable {
    public var recorder: IncidentRecorder
    public var store: UndoStore

    public init(recorder: IncidentRecorder = IncidentRecorder(), store: UndoStore = UndoStore()) {
        self.recorder = recorder
        self.store = store
    }

    public func quarantine(_ sample: ChamberSample, report: ChamberReport) throws -> (IncidentCase, UndoBatch) {
        try sample.verifyUnchanged()
        let top = report.alerts.first?.severity ?? (report.verdict == .dangerous ? .high : .medium)
        let trigger = IncidentTrigger(
            rule: "chamber-\(report.verdict.rawValue)", severity: top, title: "Detonation chamber: \(report.verdict.label)",
            detail: report.summary)
        let timeline = report.alerts.map { "[\($0.severity.label)] \($0.title) [\($0.rule)]\($0.detail.map { ": \($0)" } ?? "")" }
        let incident = try recorder.record(
            trigger: trigger, pid: nil, processTable: [], files: [sample.url], frozen: [], timeline: timeline)
        let batch = try IncidentContainment.run(IncidentContainment.plan(paths: [sample.url]), store: store, caseID: incident.id)
        return (incident, batch)
    }
}
