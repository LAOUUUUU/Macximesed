import CryptoKit
import Foundation

// Detonation chamber, phase 2 (research/detonation-chamber/PHASE2.md): the fake internet, skipped sleeps and the
// verdict rules that read what the stand-ins recorded. The guest still has no network device: the stand-ins write
// what a script asked for to /tmp/macx-requests and /tmp/macx-sleeps, and the agent prints those after the trace.

/// One request a script made through a stand-in (`curl`, `wget`, `nscurl`). Read from the guest, so untrusted.
public struct ChamberRequest: Sendable, Equatable {
    public var tool: String
    public var method: String
    public var url: String
    /// Files it tried to send (`-d @file`, `-F x=@file`, `--data-binary @file`, `-T file`), as guest paths.
    public var uploads: [String]
    /// Where it saved the answer (`-o file`, `-O file`), if anywhere.
    public var output: String?

    public init(tool: String, method: String, url: String, uploads: [String] = [], output: String? = nil) {
        self.tool = tool
        self.method = method
        self.url = url
        self.uploads = uploads
        self.output = output
    }

    public static let maxLines = 500

    /// The stand-ins' log: one request per line, tab-separated: tool, method, url, output, then upload paths.
    /// Lines that don't fit are skipped, and the URL must be http(s).
    public static func parse(_ text: String) -> [ChamberRequest] {
        text.split(separator: "\n").prefix(maxLines).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, ["curl", "wget", "nscurl"].contains(f[0]), f[2].count <= 2048,
                let u = URL(string: f[2]), ["http", "https"].contains(u.scheme?.lowercased() ?? "")
            else { return nil }
            return ChamberRequest(
                tool: f[0], method: f[1].isEmpty ? "GET" : f[1].uppercased(), url: f[2], uploads: f.dropFirst(4).filter { !$0.isEmpty },
                output: f[3].isEmpty ? nil : f[3])
        }
    }
}

/// Answers the host fetched for `--follow`, baked into the next round's image. The stand-ins look an answer up
/// by the SHA-256 of its URL.
public struct ChamberAnswers: Sendable, Equatable {
    public static let maxURLs = 10
    public static let maxBytesPerURL = 5_000_000
    public static let maxRounds = 3
    public static let guestFolder = "var/macx/answers"

    public private(set) var bodies: [String: Data] = [:]

    public init() {}

    public static func key(_ url: String) -> String { SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// False when the limits are reached: the answer isn't kept.
    @discardableResult
    public mutating func add(url: String, body: Data) -> Bool {
        guard bodies[url] != nil || bodies.count < Self.maxURLs, body.count <= Self.maxBytesPerURL else { return false }
        bodies[url] = body
        return true
    }

    /// URLs from this round that still need fetching, in the order the script asked for them.
    public func toFetch(from requests: [ChamberRequest]) -> [String] {
        var seen = Set(bodies.keys)
        var out: [String] = []
        for r in requests where r.method == "GET" && !seen.contains(r.url) {
            seen.insert(r.url)
            out.append(r.url)
        }
        return Array(out.prefix(max(0, Self.maxURLs - bodies.count)))
    }
}

/// Reads stage 2 for `--follow`, on the host: like `macx guard inspect`, nothing it fetches is run there.
public protocol ChamberFetching: Sendable {
    func fetch(_ url: String) throws -> Data
}

public enum ChamberPhase2Error: Error, Equatable, CustomStringConvertible {
    case notBuiltYet(String)

    public var description: String {
        switch self {
        case .notBuiltYet(let what): "\(what) isn't built yet (detonation chamber phase 2, research/detonation-chamber/PHASE2.md)."
        }
    }
}

/// What a sleep stand-in recorded: the seconds asked for, which it didn't wait.
public enum ChamberSleeps {
    public static let suspiciousTotal: Double = 60

    public static func parse(_ text: String) -> [Double] {
        text.split(separator: "\n").prefix(10_000).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter {
            $0.isFinite && $0 >= 0
        }
    }
}

extension ChamberJudge {
    /// Rules for what the fake internet and the sleep stand-in recorded.
    public func networkAndSleepRules(requests: [ChamberRequest], sleeps: [Double], canary: String = ChamberImage.canaryPassword)
        -> [WatchAlert]
    {
        var out: [WatchAlert] = []
        let home = guestHome.path
        for r in requests {
            let stolen = r.uploads.filter { path in
                let full = path.hasPrefix("/") ? path : home + "/Downloads/" + path
                return ChamberJudge.isBait(full, home: home)
            }
            if !stolen.isEmpty {
                out.append(
                    WatchAlert(
                        rule: "uploads-stolen-data", severity: .critical, title: "Tried to upload your passwords, cookies or wallet",
                        detail: "\(stolen.joined(separator: ", ")) to \(r.url)", pid: nil, processPath: r.tool))
            }
            if r.url.contains(canary) {
                out.append(
                    WatchAlert(
                        rule: "uploads-stolen-data", severity: .critical, title: "Tried to send the password it was given",
                        detail: r.url, pid: nil, processPath: r.tool))
            }
        }
        let waited = sleeps.reduce(0, +)
        if waited >= ChamberSleeps.suspiciousTotal {
            out.append(
                WatchAlert(
                    rule: "waits-before-acting", severity: .medium,
                    title: "Tried to wait \(Int(waited)) s first (outwaiting a sandbox); the chamber didn't wait",
                    detail: nil, pid: nil, processPath: nil))
        }
        return out
    }

    /// A bait file the chamber plants for stealers: keychain, browser data or wallet.
    static func isBait(_ path: String, home: String) -> Bool {
        let keychain = path.hasPrefix(home + "/Library/Keychains/")
        return keychain
            || ChamberImage.bait.keys.contains { key in
                let full = "/" + key
                return path == full && (full.contains("/Application Support/") || full.contains("/Cookies/"))
                    && !full.hasSuffix("notes.txt") && !full.hasSuffix("todo.txt")
            }
    }
}
