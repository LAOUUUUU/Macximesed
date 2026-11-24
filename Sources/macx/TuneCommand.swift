import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct TuneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tune",
        abstract: "Medium tier: lighter-weight macOS settings, each one reversible.",
        discussion: """
            Every tweak stores the value it replaced, and `macx tune undo` puts it back (one tweak or all). Launch agents can be switched off too (`agent:LABEL`), but only third-party ones: turning off macOS's own belongs to the Risky tier.
            """,
        subcommands: [List.self, Apply.self, Undo.self, Agents.self],
        defaultSubcommand: List.self
    )

    static func refuseRoot() throws {
        guard geteuid() != 0 else { throw UserError("Run tune without sudo: these are your settings.") }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the tweaks and which are on.")
        func run() throws {
            let applied = Set(Tune.applied())
            let sys = RealSystem()
            for t in Tune.catalog {
                let mark = applied.contains(t.id) ? "on " : (sys.read(domain: t.domain, key: t.key) == t.value ? "on*" : "   ")
                print("  [\(mark)] \(t.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(t.title): \(t.why)")
            }
            for id in applied where id.hasPrefix("agent:") { print("  [on ] \(id)  (launch agent turned off)") }
            print("\n  on* = already set that way before macx (undo leaves it alone)")
            print("Apply: macx tune apply ID ...    Undo: macx tune undo [ID ...]    Launch agents: macx tune agents")
        }
    }

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn tweaks on (IDs from `macx tune`, or agent:LABEL).")
        @Argument(help: "Tweak IDs.") var ids: [String]
        func run() throws {
            try refuseRoot()
            do { try Tune.apply(ids, uid: getuid()) } catch let p as Tune.Problem { throw UserError(p.description) }
            print("Applied: \(ids.joined(separator: ", ")). Some apps only notice after they restart. Undo: macx tune undo")
        }
    }

    struct Undo: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put tweaks back (all, if none are named).")
        @Argument(help: "Tweak IDs (default: all).") var ids: [String] = []
        func run() throws {
            try refuseRoot()
            let report = try Tune.undo(ids.isEmpty ? nil : ids)
            print("Put back \(report.restored.count) change\(report.restored.count == 1 ? "" : "s").")
            for (c, why) in report.failed { print("  Couldn't put back \(c.label): \(why)") }
        }
    }

    struct Agents: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Third-party launch agents you could switch off.")
        func run() throws {
            let dirs = [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchAgents"),
            ]
            var found = 0
            for dir in dirs {
                for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                where f.pathExtension == "plist" {
                    guard let data = try? Data(contentsOf: f),
                        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                        let label = plist["Label"] as? String, !label.hasPrefix("com.apple.")
                    else { continue }
                    let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [String])?.first ?? "")
                    print("  agent:\(label)    \((program as NSString).lastPathComponent)")
                    found += 1
                }
            }
            print(
                found == 0
                    ? "No third-party launch agents." : "\nTurn one off: macx tune apply agent:LABEL   (undo: macx tune undo agent:LABEL)")
        }
    }
}
