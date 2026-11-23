import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct Incident: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look at and contain incidents: evidence kept when watch or persist found something serious.",
        discussion: """
            A case is a private folder in ~/Library/Application Support/Macximesed/Cases with read-only copies and
            SHA-256 hashes of the files involved, the process tree (who started it, what it started), the alert
            timeline and a summary with what to do next. `macx watch` records one for every critical alert;
            `macx persist --case` records one from its findings.
            """,
        subcommands: [List.self, Show.self, Contain.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List cases, newest first.")
        func run() throws {
            let cases = try IncidentRecorder().list()
            if cases.isEmpty {
                print("No incidents recorded.")
                return
            }
            for c in cases {
                let when = DateFormatter.localizedString(from: c.created, dateStyle: .medium, timeStyle: .short)
                print("\(c.id)  \(when)  \(c.trigger.severity.label)  \(c.trigger.title)  (\(c.evidence.count) files)")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a case's summary.")
        @Argument(help: "Case ID from `macx incident`.") var id: String
        func run() throws {
            let c = try load(id)
            print((try? String(contentsOf: c.folder.appendingPathComponent("summary.md"), encoding: .utf8)) ?? "")
            print("Folder: \(c.folder.path)")
        }
    }

    struct Contain: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move the case's launch items and hidden folders into the undo folder, and show what to do next.")
        @Argument(help: "Case ID from `macx incident`.") var id: String
        @Flag(name: [.short, .long], help: "Don't ask first.") var yes = false

        func run() throws {
            let c = try load(id)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            // Only persistence: launch items, hidden Application Support folders, and programs in temp or hidden places.
            var targets: [URL] = []
            for e in c.evidence {
                let p = e.originalPath
                if p.contains("/Library/LaunchAgents/") || p.contains("/Library/LaunchDaemons/") {
                    targets.append(URL(fileURLWithPath: p))
                } else if let r = p.range(of: "/Library/Application Support/."), p.hasPrefix(home) || p.hasPrefix("/Library") {
                    let rest = p[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
                    targets.append(URL(fileURLWithPath: String(p[..<r.upperBound]) + rest))
                } else if ["/tmp/", "/private/tmp/", "/Users/Shared/", "\(home)/Downloads/"].contains(where: { p.hasPrefix($0) }) {
                    targets.append(URL(fileURLWithPath: p))
                }
            }
            let plan = IncidentContainment.plan(paths: targets)
            if plan.toMove.isEmpty {
                print("Nothing in this case to move aside (no launch items, hidden folders or temp-folder programs that still exist).")
            } else {
                print("Will move into the undo folder (nothing is deleted):")
                plan.toMove.forEach { print("  \($0.path)") }
                plan.refused.forEach { print("  skipped \($0.0.path): \($0.1)") }
                let commands = IncidentContainment.bootoutCommands(for: plan.toMove, uid: getuid())
                guard yes || askYes("Move these \(plan.toMove.count) items?") else {
                    print("Nothing changed.")
                    return
                }
                do {
                    let batch = try IncidentContainment.run(plan, store: UndoStore(), caseID: c.id)
                    print("Moved \(batch.items.count). Undo with: macx undo restore \(batch.id)")
                    if !batch.failed.isEmpty {
                        print("Couldn't move \(batch.failed.count) (they need root): run `sudo macx incident contain \(c.id)`.")
                    }
                } catch UndoError.nothingToStash {
                    print("Couldn't move any of them (they need root). Run: sudo macx incident contain \(c.id)")
                }
                if !commands.isEmpty {
                    print("\nIf they're still running, stop them with:")
                    commands.forEach { print("  \($0)") }
                }
            }
            print("\nThen, from a different, clean device: change the passwords that were on this Mac, sign out other")
            print("sessions, turn on two-factor sign-in, and replace SSH and API keys. Full checklist: macx incident show \(c.id)")
        }
    }

    static func load(_ id: String) throws -> IncidentCase {
        do { return try IncidentRecorder().load(id: id) } catch { throw UserError("No incident \(id). See `macx incident`.") }
    }
}

/// Recording a case from `macx watch` (as root under sudo) or `macx persist`.
enum IncidentCapture {
    /// Case folders live in the real user's home and belong to them, even when macx runs as root.
    static func recorder(home: URL) -> IncidentRecorder {
        IncidentRecorder(root: home.appendingPathComponent("Library/Application Support/Macximesed/Cases"))
    }

    static func handOver(_ folder: URL, uid: uid_t, gid: gid_t) {
        guard geteuid() == 0 else { return }
        var paths = [folder.deletingLastPathComponent().path, folder.path]
        if let walker = FileManager.default.enumerator(atPath: folder.path) {
            while let p = walker.nextObject() as? String { paths.append(folder.appendingPathComponent(p).path) }
        }
        for p in paths { chown(p, uid, gid) }
    }

    static func fromAlert(_ a: WatchAlert, frozen: [Int], home: URL, uid: uid_t, gid: gid_t, timeline: [String]) -> IncidentCase? {
        var files: [URL] = []
        if let d = a.detail?.split(separator: "\n").first.map(String.init), d.hasPrefix("/"), FileManager.default.fileExists(atPath: d) {
            files.append(URL(fileURLWithPath: d))
        }
        if let p = a.processPath, !p.isEmpty { files.append(URL(fileURLWithPath: p)) }
        let trigger = IncidentTrigger(rule: a.rule, severity: a.severity, title: a.title, detail: a.detail)
        guard
            let c = try? recorder(home: home).record(
                trigger: trigger, pid: a.pid, processTable: ProcessTree.snapshot(), files: files, frozen: frozen, timeline: timeline)
        else { return nil }
        handOver(c.folder, uid: uid, gid: gid)
        return c
    }
}
