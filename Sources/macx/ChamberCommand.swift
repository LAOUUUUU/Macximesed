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

        func run() throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            guard (5...300).contains(seconds) else { throw UserError("--seconds must be between 5 and 300.") }
            let manifest = try ChamberManifest.bundled()
            let store = ChamberStore()
            guard store.isInstalled(for: manifest) else { throw UserError("The chamber isn't set up yet. Run: macx chamber setup") }
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let sample: ChamberSample
            do { sample = try ChamberSample(pinning: url) } catch { throw UserError("Can't read \(file).") }
            print("\(url.lastPathComponent)  SHA-256 \(sample.sha256)")
            if let feed = HashFeed.loadCached(), let name = try? feed.lookup(sha256: sample.sha256) {
                print("Known malware (\(name)). It doesn't need the chamber: don't open it.")
                throw ExitCode(2)
            }

            let image: Data
            do {
                image = try ChamberImage.build(rootfs: store.rootfs, sample: sample, seconds: seconds)
            } catch let p as ChamberImage.Problem {
                throw UserError(p.description + " Try: macx check \(file)")
            }
            print("Running it in the chamber (no network, \(seconds) s at most)...")
            let run: ChamberVM.Run
            do {
                run = try ChamberVM.run(kernel: store.kernel, initramfs: image, timeLimit: TimeInterval(seconds + 30))
            } catch let p as ChamberVM.Problem {
                throw UserError(p.description)
            }
            guard run.console.ready else {
                throw UserError("The chamber didn't get as far as running the script (it stopped after \(Int(run.seconds)) s).")
            }

            let parsed = StraceLog.parse(run.console.trace)
            let samplePID = parsed.events.first?.process?.pid
            let report = ChamberJudge(guestHome: URL(fileURLWithPath: ChamberImage.guestHome)).judge(
                events: parsed.events, samplePID: samplePID, skipped: parsed.skipped, truncated: !run.console.complete)
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
