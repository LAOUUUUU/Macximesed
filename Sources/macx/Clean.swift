import AppKit
import ArgumentParser
import Foundation
import MacxCore

extension Tier: ExpressibleByArgument {}

/// Bundle IDs of running apps, straight from the system.
func runningBundleIDs() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
}

/// A plain message for the user. Unlike ValidationError, ArgumentParser prints it without the usage text.
struct UserError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Reads one line from the terminal. Returns false when there's no terminal to ask.
func askYes(_ question: String) -> Bool {
    guard isatty(STDIN_FILENO) != 0 else { return false }
    print("\(question) [y/N] ", terminator: "")
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
    return answer == "y" || answer == "yes"
}

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Free space. Everything is moved to the undo folder first; nothing is deleted."
    )

    @Option(name: .shortAndLong, help: "Risk level: safe (only safe is built so far).")
    var tier: Tier = .safe

    @Flag(name: .long, help: "List what would be cleaned and change nothing.")
    var dryRun = false

    @Option(name: .long, parsing: .upToNextOption, help: "Only these item IDs (from --dry-run).")
    var only: [String] = []

    @Flag(name: .long, help: "Also clean items a running app or open file is using.")
    var includeInUse = false

    @Flag(name: .long, help: "Also clean caches whose owner can't be identified (shown as \"unknown owner\").")
    var includeUnknown = false

    @Flag(name: [.short, .long], help: "Don't ask before moving.")
    var yes = false

    func run() throws {
        guard tier == .safe else {
            throw UserError("The \(tier.rawValue) tier isn't built yet. See STATUS.md.")
        }
        let all = CleanupCatalog.safe(.current(runningBundleIDs: runningBundleIDs()))
        let unknown = Set(only).subtracting(all.map(\.id))
        if !unknown.isEmpty {
            throw UserError("Unknown item ID: \(unknown.sorted().joined(separator: ", ")). Run with --dry-run to see the IDs.")
        }
        let chosen = CleanupCatalog.select(all, only: Set(only), includeInUse: includeInUse, includeUnknown: includeUnknown)
        let chosenIDs = Set(chosen.map(\.id))

        print("Safe cleanup (\(dryRun ? "dry run, nothing changes" : "items are moved to the undo folder"))\n")
        for item in all.sorted(by: { $0.bytes > $1.bytes }) {
            let mark = chosenIDs.contains(item.id) ? "+" : " "
            let size = formatBytes(item.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
            var line = "  \(mark) \(size)  \(item.id.padding(toLength: 40, withPad: " ", startingAt: 0))  \(item.owner.label)"
            if let user = item.inUseBy, !chosenIDs.contains(item.id) { line += "   (in use: \(user))" }
            print(line)
        }
        let total = chosen.reduce(0) { $0 + $1.bytes }
        print("\n  \(chosen.count) items, \(formatBytes(total)) to free. Lines marked + are included.")
        if !includeUnknown, only.isEmpty, all.contains(where: { $0.owner == .unknown }) {
            print("  Items with an unknown owner are left out; add them with --include-unknown or pick them with --only.")
        }

        guard !dryRun, !chosen.isEmpty else { return }
        guard yes || askYes("Move these \(chosen.count) items to the undo folder?") else {
            print("Nothing changed.")
            return
        }
        let batch = try CleanupCatalog.run(chosen, store: UndoStore())
        print("\nMoved \(batch.items.count) paths (\(formatBytes(batch.totalBytes))). Undo with: macx undo restore \(batch.id)")
        if !batch.failed.isEmpty {
            print("Could not move \(batch.failed.count) paths (in use or no permission); they were left alone.")
        }
        print("The space comes back when the batch is purged: macx undo purge (batches older than 7 days).")
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, restore or purge what cleanups moved aside.",
        subcommands: [List.self, Restore.self, Purge.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show undo batches.")
        func run() throws {
            let batches = try UndoStore().batches()
            if batches.isEmpty {
                print("Nothing in the undo folder.")
                return
            }
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            for b in batches {
                print("\(b.id)  \(df.string(from: b.createdAt))  \(formatBytes(b.totalBytes))  \(b.items.count) paths  \(b.reason)")
            }
        }
    }

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put a batch back where it came from.")
        @Argument(help: "Batch ID from `macx undo list`.") var id: String
        func run() throws {
            let r = try UndoStore().restore(id: id)
            print("Restored \(r.restored.count) paths.")
            if !r.skipped.isEmpty {
                print("Kept \(r.skipped.count) in the undo folder because something new is already at the original place:")
                r.skipped.forEach { print("  \($0)") }
            }
        }
    }

    struct Purge: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Permanently delete batches older than N days.")
        @Option(help: "Age in days.") var days: Int = 7
        @Flag(name: [.short, .long], help: "Don't ask first.") var yes = false
        func run() throws {
            let store = UndoStore()
            let cutoff = Date().addingTimeInterval(-Double(max(days, 0)) * 86400)
            let old = try store.batches().filter { $0.createdAt < cutoff }
            if old.isEmpty {
                print("No batches older than \(days) days.")
                return
            }
            let total = old.reduce(0) { $0 + $1.totalBytes }
            print("\(old.count) batches, \(formatBytes(total)), older than \(days) days. This can't be undone.")
            guard yes || askYes("Delete them for good?") else {
                print("Nothing changed.")
                return
            }
            let purged = try store.purge(olderThan: Double(max(days, 0)) * 86400)
            print("Deleted \(purged.count) batches.")
        }
    }
}
