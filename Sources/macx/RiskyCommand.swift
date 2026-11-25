import ArgumentParser
import Foundation
import MacxCore

extension RiskyItem: ExpressibleByArgument {}

struct RiskyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "risky",
        abstract: "The Risky tier: system settings that trade a feature for speed, disk or battery. Three confirmations each, with undo.",
        subcommands: [List.self, Apply.self, UndoRisky.self],
        defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "What each item does, what it breaks, and whether it's on.")

        func run() throws {
            let ledger = RiskyLedger.load()
            for i in Risky.catalog {
                print("\(i.item.rawValue)  [\(Risky.state(i.item, ledger: ledger))]  \(i.title)")
                var does = i.does
                if i.item == .hibernation, let b = Risky.sleepImageBytes() { does += " On this Mac: \(formatBytes(b))." }
                print("  Does:   \(does)")
                print("  Breaks: \(i.breaks)")
                print("  Undo:   \(i.undoable ? "macx risky undo \(i.item.rawValue)" : "none, it's a delete")")
            }
            if !ledger.before.isEmpty { print("\nUndo script (works without macx): sudo sh '\(RiskyLedger.script.path)'") }
        }
    }

    struct Apply: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn one item on, after three confirmations. Needs sudo.")

        @Argument(help: "spotlight, hibernation, powernap or snapshots.") var item: RiskyItem
        @Flag(help: .hidden) var confirmedInApp = false

        func run() throws {
            guard geteuid() == 0 else { throw UserError("This changes system settings: run it with sudo.") }
            let info = Risky.info(item)
            if !confirmedInApp {
                guard isatty(STDIN_FILENO) != 0 else { throw UserError("Risky items need you at a terminal to confirm.") }
                print("\(info.title)\n  Does:   \(info.does)\n  Breaks: \(info.breaks)")
                if !info.undoable { print("  This one can't be undone.") }
                guard askYes("1/3  Continue?") else { throw UserError("Left as it was.") }
                print("2/3  Type \(item.rawValue) to confirm: ", terminator: "")
                guard Risky.confirms(item, typed: readLine() ?? "") else { throw UserError("That wasn't it. Left as it was.") }
                print("3/3  Last chance in 5 seconds…")
                Thread.sleep(forTimeInterval: 5)
                guard askYes("3/3  Do it now?") else { throw UserError("Left as it was.") }
            }
            var ledger = RiskyLedger.load()
            try Risky.apply(item, ledger: &ledger)
            try ledger.save()
            Log.info("risky", "applied \(item.rawValue)")
            print("Done: \(info.title).")
            if info.undoable { print("Undo: sudo macx risky undo \(item.rawValue)  (or sudo sh '\(RiskyLedger.script.path)')") }
        }
    }

    struct UndoRisky: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "undo", abstract: "Put back what macx changed (one item, or all of them). Needs sudo.")

        @Argument(help: "One item; leave out to undo everything macx changed.") var item: RiskyItem?

        func run() throws {
            guard geteuid() == 0 else { throw UserError("This changes system settings: run it with sudo.") }
            var ledger = RiskyLedger.load()
            let items = item.map { [$0] } ?? RiskyItem.allCases.filter { ledger.before[$0.rawValue] != nil }
            if items.isEmpty { print("Nothing to undo: macx hasn't changed any Risky item.") }
            for i in items {
                try Risky.undo(i, ledger: &ledger)
                try ledger.save()
                Log.info("risky", "undid \(i.rawValue)")
                print("Put back: \(Risky.info(i).title).")
            }
        }
    }
}
