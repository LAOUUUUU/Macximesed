import ArgumentParser
import Foundation
import MacxCore

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List apps, find ones you don't use, and uninstall them with their leftovers (undoable).",
        subcommands: [List.self, Remove.self, Leftovers.self],
        defaultSubcommand: List.self
    )

    static func lastUsedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let days = Int(now.timeIntervalSince(date) / 86400)
        return days <= 0 ? "today" : days == 1 ? "1 day ago" : "\(days) days ago"
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List every app on this Mac, wherever it is (from Spotlight).")

        @Flag(help: "Only apps not opened in --days days. Apps with no known date are never listed as unused.")
        var unused = false

        @Option(help: "Days without use that count as unused.")
        var days: Int = 90

        @Flag(help: "Only Intel apps (they run through Rosetta, which is slower).")
        var intel = false

        @Option(help: "Sort by: size, name or used.")
        var sort: String = "size"

        func run() throws {
            var apps = AppScanner.discover(home: FileManager.default.homeDirectoryForCurrentUser)
            if unused { apps = AppScanner.unused(apps, olderThanDays: days) }
            if intel { apps = apps.filter { !$0.architectures.contains(.arm64) && $0.architectures.contains(.x86_64) } }
            switch sort {
            case "name": break
            case "used": apps.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
            default: apps.sort { $0.bytes > $1.bytes }
            }
            for a in apps {
                let size = formatBytes(a.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
                let kind = AppArch.kind(a.architectures).padding(toLength: 17, withPad: " ", startingAt: 0)
                let used = ((a.lastUsedIsEstimate ? "~" : "") + Apps.lastUsedText(a.lastUsed)).padding(
                    toLength: 14, withPad: " ", startingAt: 0)
                print(
                    "  \(size)  \(kind)  \(used)  \(a.name)  [\(a.bundleID)]  \((a.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)"
                )
            }
            let total = apps.reduce(0) { $0 + $1.bytes }
            print("\n  \(apps.count) apps, \(formatBytes(total)).")
            if apps.contains(where: \.lastUsedIsEstimate) {
                print("  ~ means Spotlight had no date, so it's estimated from when the app last changed its own files.")
            }
            if unused { print("  Remove one with: macx apps remove <name or bundle ID>") }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Uninstall an app and its leftovers into the undo folder (macx undo restore brings it back)."
        )

        @Argument(help: "App name or bundle ID.")
        var app: String

        @Flag(name: .long, help: "Also move folders named exactly like the app (another program could share the name).")
        var includeNameMatches = false

        @Flag(name: [.short, .long], help: "Don't ask first.")
        var yes = false

        func run() throws {
            let apps = AppScanner.discover(includeSystem: true, lastUsed: { _ in nil })
            let matches = apps.filter {
                $0.bundleID.caseInsensitiveCompare(app) == .orderedSame || $0.name.caseInsensitiveCompare(app) == .orderedSame
            }
            guard matches.count == 1, let target = matches.first else {
                if matches.isEmpty { throw UserError("No app called \"\(app)\". Run `macx apps` to see names.") }
                throw UserError("More than one app matches; use the bundle ID: \(matches.map(\.bundleID).joined(separator: ", "))")
            }
            let plan: UninstallPlan
            do {
                plan = try AppUninstaller.plan(
                    target, home: FileManager.default.homeDirectoryForCurrentUser,
                    runningBundleIDs: runningBundleIDs(), includeNameMatches: includeNameMatches)
            } catch UninstallError.systemApp {
                throw UserError(
                    "\(target.name) is part of macOS (sealed system volume). It can only be removed at the Extreme level, which isn't built yet."
                )
            } catch UninstallError.appleApp {
                throw UserError("\(target.name) is a built-in Apple app, not an App Store download, so it's left alone.")
            } catch UninstallError.running(let name) {
                throw UserError("\(name) is running. Quit it first.")
            }

            print("Uninstall \(target.name) \(target.version ?? "") (\(formatBytes(plan.bytes)) in total):")
            plan.paths.forEach { print("  \($0.path)") }
            let byName = AppLeftovers.nameMatches(for: target, home: FileManager.default.homeDirectoryForCurrentUser)
                .filter { !plan.paths.contains($0) }
            if !byName.isEmpty {
                print("  Not included (only the name matches, add --include-name-matches to move them too):")
                byName.forEach { print("    \($0.path)") }
            }
            guard yes || askYes("Move these \(plan.paths.count) items to the undo folder?") else {
                print("Nothing changed.")
                return
            }
            let batch = try AppUninstaller.run(plan, store: UndoStore())
            if batch.failed.contains(target.url.path) {
                print("\nCould not move the app itself (it's probably owned by root; try again with sudo).")
            }
            print("\nMoved \(batch.items.count) items. Undo with: macx undo restore \(batch.id)")
            if !batch.failed.isEmpty { print("Left alone (no permission or in use): \(batch.failed.count) paths.") }
        }
    }

    struct Leftovers: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find leftovers of apps that are already gone, and optionally move them to the undo folder."
        )

        @Option(name: .long, parsing: .upToNextOption, help: "Move these IDs (from the list) to the undo folder.")
        var remove: [String] = []

        @Flag(name: [.short, .long], help: "Don't ask first.")
        var yes = false

        func run() throws {
            let orphans = AppLeftovers.orphans(home: FileManager.default.homeDirectoryForCurrentUser, bundles: .current())
            if remove.isEmpty {
                for o in orphans.sorted(by: { $0.bytes > $1.bytes }) {
                    print("  \(formatBytes(o.bytes).padding(toLength: 9, withPad: " ", startingAt: 0))  \(o.id)  (\(o.paths.count) items)")
                }
                print("\n  \(orphans.count) groups named after a bundle ID that no app or helper on this Mac has.")
                print("  Some belong to command-line tools or web apps, so check each. Remove with --remove <ID> ...")
                return
            }
            let chosen = orphans.filter { remove.contains($0.id) }
            let unknown = Set(remove).subtracting(chosen.map(\.id))
            if !unknown.isEmpty { throw UserError("Unknown ID: \(unknown.sorted().joined(separator: ", "))") }
            let paths = chosen.flatMap(\.paths)
            paths.forEach { print("  \($0.path)") }
            guard yes || askYes("Move these \(paths.count) items to the undo folder?") else {
                print("Nothing changed.")
                return
            }
            let batch = try UndoStore().stash(paths, reason: "leftovers: \(chosen.map(\.id).joined(separator: ", "))")
            print("\nMoved \(batch.items.count) items. Undo with: macx undo restore \(batch.id)")
        }
    }
}
