import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct Chamber: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a suspicious script in a throwaway virtual machine and see what it does (the detonation chamber).",
        discussion: """
            The light chamber is a tiny Linux VM (about 60 MB) with no network, no disk and nothing shared with this Mac. A script runs there once, with Mac-only commands replaced by stand-ins and bait files where a stealer looks (keychain, browser passwords, wallets). Everything it does is recorded and judged here. A bad result can quarantine the file into a restorable incident case. It runs scripts; Mac apps and programs keep the regular file checks (macx check). A clean result means nothing was seen, not that the file is safe.
            """,
        subcommands: [Status.self, Setup.self, Run.self, Remove.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Is the chamber set up?")
        func run() throws {
            let store = ChamberStore()
            guard let manifest = try? ChamberManifest.bundled() else {
                print("The light chamber isn't available for this Mac's processor (\(ChamberManifest.hostArch)) yet.")
                return
            }
            if store.isInstalled(for: manifest) {
                print("Light chamber: ready (Alpine \(manifest.alpine), \(manifest.arch)), \(allocatedSize(of: store.root) / 1_000_000) MB")
                print("  \(store.root.path)")
                print("Run a script in it: macx chamber run FILE")
            } else {
                let mb = manifest.files.reduce(0) { $0 + $1.bytes } / 1_000_000
                print("Light chamber: not set up. `macx chamber setup` downloads about \(mb) MB from Alpine Linux.")
            }
        }
    }

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download, check and unpack the chamber (about 50 MB, once).")
        @Flag(name: .shortAndLong, help: "Don't ask before downloading.") var yes = false

        func run() throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let manifest = try ChamberManifest.bundled()
            let mirror = ProcessInfo.processInfo.environment["MACX_CHAMBER_MIRROR"].map { URL(fileURLWithPath: $0) }
            let setup = ChamberSetup(
                manifest: manifest, downloader: mirror.map { LocalMirrorDownloader(folder: $0) } ?? URLSessionChamberDownloader())
            let plan = setup.plan()
            print("The light chamber needs \(plan.files.count) files from Alpine Linux \(manifest.alpine) (\(manifest.arch)):")
            for f in plan.files { print("  \(f.name) \(f.version)  \(String(format: "%.1f", Double(f.bytes) / 1e6)) MB") }
            print(
                "Download: \(String(format: "%.1f", Double(plan.downloadBytes) / 1e6)) MB from dl-cdn.alpinelinux.org. Every file is checked against its SHA-256 pinned in macx before it's used."
            )
            print("Stored in: \(setup.store.root.path) (about 60 MB after unpacking)")
            if let mirror { print("Reading the files from \(mirror.path) instead of downloading (MACX_CHAMBER_MIRROR).") }
            guard yes || askYes("Download and set it up?") else {
                print("Nothing downloaded.")
                return
            }
            do {
                try setup.run { print("  \($0)") }
            } catch let p as ChamberSetup.Problem {
                throw UserError(p.description)
            }
            print("Done. Try it: macx chamber run FILE")
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a script in the chamber and judge what it did.")
        @Argument(help: "The script to run.", completion: .file()) var file: String
        @Option(help: "Seconds the script may run (5-300).") var seconds: Int = 60
        @Flag(name: .shortAndLong, help: "Quarantine without asking when the verdict is DON'T OPEN THIS.") var yes = false
        @Flag(help: "Never quarantine, just report.") var noQuarantine = false
        @Flag(
            help:
                "Fetch what the script downloads (read only, on this Mac, like guard inspect) and run it again with that inside. The site sees your IP."
        )
        var follow = false

        func run() throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            guard (5...300).contains(seconds) else { throw UserError("--seconds must be between 5 and 300.") }
            if follow { throw UserError(ChamberPhase2Error.notBuiltYet("--follow").description) }
            if (file as NSString).pathExtension.lowercased() == "pkg" {
                throw UserError(
                    ChamberPhase2Error.notBuiltYet("Running a package's install scripts").description + " Meanwhile: macx check \(file)")
            }
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            if let pinned = try? ChamberSample(pinning: url) { print("\(url.lastPathComponent)  SHA-256 \(pinned.sha256)") }
            if ChamberSession.isSetUp() { print("Running it in the chamber (no network, \(seconds) s at most)...") }
            let outcome: ChamberSession.Outcome
            do {
                outcome = try ChamberSession.run(url, seconds: seconds)
            } catch let p as ChamberSession.Problem {
                switch p {
                case .knownMalware:
                    print(p.description)
                    throw ExitCode(2)
                case .cantRun(let why): throw UserError(why + " Try: macx check \(file)")
                case .unreadable: throw UserError("Can't read \(file).")
                default: throw UserError(p.description)
                }
            }
            let (sample, report, run) = (outcome.sample, outcome.report, outcome.run)
            Self.show(report, run: run)

            guard report.verdict != .nothingSeen, !noQuarantine else {
                if report.verdict == .dangerous { throw ExitCode(2) }
                return
            }
            if report.verdict == .dangerous,
                yes || askYes("Quarantine \(url.lastPathComponent)? It moves into a case folder and the undo folder, restorable.")
            {
                let (incident, batch) = try ChamberQuarantine().quarantine(sample, report: report)
                print("Quarantined. Case: macx incident show \(incident.id)    Undo: macx undo restore \(batch.id)")
            }
            if report.verdict == .dangerous { throw ExitCode(2) }
        }

        static func show(_ r: ChamberReport, run: ChamberVM.Run) {
            Swift.print(
                "\nVerdict: \(r.verdict.label)  (\(String(format: "%.1f", run.seconds)) s\(run.stoppedByTimeLimit ? ", stopped at the time limit" : ""))"
            )
            for a in r.alerts {
                Swift.print("  \(a.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(a.title)  [\(a.rule)]")
                if let d = a.detail, !d.isEmpty { Swift.print("           \(d.prefix(200))") }
            }
            Swift.print("\n\(r.summary)")
            let out = run.console.output.split(separator: "\n").prefix(8)
            if !out.isEmpty {
                Swift.print("\nWhat it printed (first lines):")
                out.forEach { Swift.print("  | \($0.prefix(160))") }
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete the chamber's files (setup can download them again).")
        @Flag(name: .shortAndLong, help: "Don't ask.") var yes = false
        func run() throws {
            let store = ChamberStore()
            guard FileManager.default.fileExists(atPath: store.root.path) else {
                print("Nothing to remove.")
                return
            }
            guard yes || askYes("Delete \(store.root.path)? This is a permanent delete of the chamber's downloaded files.") else { return }
            try FileManager.default.removeItem(at: store.root)
            print("Removed.")
        }
    }
}
