import ArgumentParser
import Foundation
import MacxCore

struct Persist: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Find everything set to start by itself (launch daemons and agents, login items, cron, shell files) and flag what looks like malware.",
        discussion: """
            Read-only: nothing is changed or removed. Save a baseline once with --baseline, then --diff shows
            what was added, removed or changed since, which is how a new infection shows up.
            """
    )

    @Flag(help: "List every item, not only the ones with findings.")
    var all = false

    @Option(help: "Lowest severity to show: info, low, medium, high, critical.")
    var minSeverity: String = "low"

    @Flag(help: "Save what's there now as the baseline.")
    var baseline = false

    @Flag(help: "Compare with the saved baseline.")
    var diff = false

    @Flag(help: "Record an incident case (evidence, hashes, summary) from the high and critical findings.")
    var `case` = false

    func run() throws {
        let items = PersistenceScanner.current()
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let minimum = Severity.allCases.first(where: { String(describing: $0) == minSeverity.lowercased() }) else {
            throw UserError("Unknown severity \"\(minSeverity)\". Use info, low, medium, high or critical.")
        }

        if baseline {
            try PersistenceBaseline.save(items)
            print("Saved a baseline of \(items.count) items to \(PersistenceBaseline.defaultFile.path).")
            print("Later, run `macx persist --diff` to see what changed.")
            return
        }

        if diff {
            let old: [PersistenceItem]
            do { old = try PersistenceBaseline.load() } catch {
                throw UserError("No baseline yet. Save one with `macx persist --baseline`.")
            }
            let d = PersistenceBaseline.diff(old: old, new: items)
            if d.isEmpty { print("Nothing changed since the baseline (\(items.count) items).") }
            for (title, list) in [("Added", d.added), ("Changed", d.changed), ("Removed", d.removed)] where !list.isEmpty {
                print("\(title):")
                list.forEach { print("  \(describe($0))") }
            }
            let fresh = PersistenceRules.evaluate(d.added + d.changed, home: home)
            if !fresh.isEmpty {
                print("\nFindings on added or changed items:")
                printFindings(fresh)
            }
            return
        }

        let findings = PersistenceRules.evaluate(items, home: home).filter { $0.severity >= minimum }
        if all {
            for kind in PersistenceKind.allCases {
                let ofKind = items.filter { $0.kind == kind }
                guard !ofKind.isEmpty else { continue }
                print("\(kind.label) (\(ofKind.count))")
                ofKind.forEach { print("  \(describe($0))") }
                print("")
            }
        }
        print("Scanned \(items.count) items.")
        if findings.isEmpty {
            print("No findings at \(minSeverity) or above.")
        } else {
            print("")
            printFindings(findings)
            let serious = findings.filter { $0.severity >= .high }
            if `case`, let top = serious.first {
                var files: [URL] = []
                for f in serious {
                    files.append(URL(fileURLWithPath: f.item.path))
                    if let p = f.item.program, p.hasPrefix("/") { files.append(URL(fileURLWithPath: p)) }
                }
                let trigger = IncidentTrigger(
                    rule: top.rule, severity: top.severity, title: "\(serious.count) serious persistence finding(s): \(top.title)",
                    detail: serious.map { "\($0.rule): \($0.item.path)" }.joined(separator: "\n"))
                let c = try IncidentRecorder().record(trigger: trigger, pid: nil, processTable: [], files: files, frozen: [], timeline: [])
                print("\nRecorded incident \(c.id): macx incident show \(c.id)  ·  contain with: macx incident contain \(c.id)")
            } else if `case` {
                print("\nNo high or critical findings, so no incident was recorded.")
            }
        }
    }

    func describe(_ item: PersistenceItem) -> String {
        var parts = [item.label ?? (item.path as NSString).lastPathComponent]
        if let p = item.program { parts.append("→ \(p)") }
        if let s = item.signature { parts.append("[\(s.label)]") }
        if let t = item.teamID { parts.append("[team \(t)]") }
        if item.kind == .shellStartup, let d = item.detail { parts.append(": \(d)") }
        parts.append("(\(item.path))")
        return parts.joined(separator: " ")
    }

    func printFindings(_ findings: [Finding]) {
        // One block per item, its findings listed under it, most severe item first.
        var order: [String] = []
        var byItem: [String: [Finding]] = [:]
        for f in findings {
            if byItem[f.item.key] == nil { order.append(f.item.key) }
            byItem[f.item.key, default: []].append(f)
        }
        for key in order {
            guard let fs = byItem[key], let first = fs.first else { continue }
            print(
                "\(first.severity.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(first.item.kind.label): \(describe(first.item))"
            )
            fs.forEach { print("         - \($0.title)  [\($0.rule)]") }
        }
        let counts = Severity.allCases.reversed().compactMap { s -> String? in
            let n = findings.filter { $0.severity == s }.count
            return n > 0 ? "\(n) \(String(describing: s))" : nil
        }
        print("\nFindings: \(counts.joined(separator: ", ")). Nothing was changed.")
    }
}
