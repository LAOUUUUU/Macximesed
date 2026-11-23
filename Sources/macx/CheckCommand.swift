import ArgumentParser
import Foundation
import MacxCore

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a download before you open it: app, installer package, disk image, script or any file.",
        discussion: """
            Reads the signature, asks Gatekeeper what it would do, shows who downloaded it (quarantine flag) and its
            SHA-256, lists what it would set up to run by itself, and reads scripts (including install scripts inside
            packages and files inside disk images) for download-and-run, hidden base64 code, quarantine stripping and
            password prompts. Nothing is opened or run. Disk images are mounted read-only and hidden, then ejected.

            --online also looks the SHA-256 up on abuse.ch MalwareBazaar. Only the hash is sent. It needs a free
            Auth-Key in the MACX_MALWAREBAZAAR_KEY environment variable.
            """
    )

    @Argument(help: "Files to check.", completion: .file())
    var paths: [String]

    @Flag(help: "Look the SHA-256 up on MalwareBazaar (sends only the hash).")
    var online = false

    func run() throws {
        // Offline by default: the signed hash feed cached by the daily update check.
        var lookup: HashLookup? = HashFeed.loadCached()
        if online {
            guard let key = ProcessInfo.processInfo.environment["MACX_MALWAREBAZAAR_KEY"], !key.isEmpty else {
                throw UserError("--online needs a MalwareBazaar Auth-Key in MACX_MALWAREBAZAAR_KEY (free at https://auth.abuse.ch/).")
            }
            lookup = MalwareBazaarLookup(authKey: key)
        }
        let checker = FileChecker(signatures: GuardedSignatureChecker(), lookup: lookup)
        var worst = Verdict.ok
        for (i, path) in paths.enumerated() {
            if i > 0 { print("") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard PrivacyPolicy.current.allows(url) || FileManager.default.isReadableFile(atPath: url.path) else {
                throw UserError("\(path) is in a privacy-guarded folder. Give macx Full Disk Access first (macx privacy).")
            }
            let report: FileReport
            do { report = try checker.check(url) } catch FileCheckError.notFound(let p) { throw UserError("No such file: \(p)") }
            printReport(report)
            worst = max(worst, report.verdict)
        }
        if worst == .dangerous { throw ExitCode(2) }
    }

    func printReport(_ r: FileReport, indent: String = "") {
        let verdict: String =
            switch r.verdict {
            case .ok: "Looks OK"
            case .partlyUnknown: "Looks OK so far (parts couldn't be checked)"
            case .caution: "Be careful"
            case .dangerous: "DON'T OPEN THIS"
            }
        print("\(indent)\(r.path.lastPathComponent)  (\(r.kind.label))  →  \(verdict)")
        if let s = r.signature { print("\(indent)  Signature:   \(s.label)") }
        if let g = r.gatekeeper {
            let what = g.accepted ? "allowed" : "blocked"
            let src = [g.source, g.origin, g.error].compactMap { $0 }.joined(separator: ", ")
            print("\(indent)  Gatekeeper:  \(what)\(src.isEmpty ? "" : " (\(src))")")
        }
        if let q = r.quarantine {
            let when = q.date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "unknown time"
            print("\(indent)  Downloaded:  by \(q.agent ?? "an unknown app"), \(when)  [quarantine \(q.flags)]")
        }
        if let h = r.sha256 { print("\(indent)  SHA-256:     \(h)") }
        if !r.installs.isEmpty {
            print("\(indent)  Sets up:")
            r.installs.forEach { print("\(indent)    - \($0.label)") }
        }
        if !r.findings.isEmpty {
            print("\(indent)  Findings:")
            for f in r.findings {
                print("\(indent)    \(f.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(f.title)  [\(f.rule)]")
                if let d = f.detail {
                    d.split(separator: "\n").forEach { print("\(indent)             \($0)") }
                }
            }
        }
        if !r.inner.isEmpty {
            print("\(indent)  Inside:")
            r.inner.forEach { printReport($0, indent: indent + "    ") }
        }
    }
}
