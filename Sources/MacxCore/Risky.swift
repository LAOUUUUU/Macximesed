import Foundation

/// The Risky tier (research/risky-tier/RESEARCH.md): system settings that trade a feature for a little speed, disk or
/// battery. Each stores what it replaced before changing anything, and has an undo (except the snapshot purge, which is a
/// delete and says so). Needs root. Never touches SIP, Gatekeeper, XProtect, FileVault, the firewall or macx's watch.
public enum RiskyItem: String, CaseIterable, Sendable {
    case spotlight
    case hibernation
    case powerNap = "powernap"
    case snapshots
}

public struct RiskyInfo: Sendable {
    public var item: RiskyItem
    public var title: String
    public var does: String
    public var breaks: String
    public var undoable: Bool
}

public enum RiskyError: Error, Equatable, CustomStringConvertible {
    case notUndoable(String)
    case nothingStored(String)
    case failed(String)
    public var description: String {
        switch self {
        case .notUndoable(let s): "\(s) is a delete and can't be undone."
        case .nothingStored(let s): "Nothing stored for \(s): it wasn't changed by macx."
        case .failed(let s): s
        }
    }
}

/// The values each item replaced, kept in a root-owned file next to the undo script.
public struct RiskyLedger: Codable, Sendable, Equatable {
    public var before: [String: [String: String]] = [:]
    public init() {}

    public static let folder = URL(fileURLWithPath: "/Library/Application Support/Macximesed")
    public static let file = folder.appendingPathComponent("risky.json")
    public static let script = folder.appendingPathComponent("undo-risky.sh")

    public static func load(from file: URL = RiskyLedger.file) -> RiskyLedger {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(RiskyLedger.self, from: $0) } ?? RiskyLedger()
    }

    /// Writes the ledger and the undo script (0600 / 0700, root's when run as root).
    public func save(to file: URL = RiskyLedger.file, script: URL = RiskyLedger.script) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Risky.undoScript(self).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }
}

public enum Risky {
    static let pmset = "/usr/bin/pmset"
    static let mdutil = "/usr/bin/mdutil"
    static let tmutil = "/usr/bin/tmutil"
    static let sleepImage = "/private/var/vm/sleepimage"

    public static let catalog: [RiskyInfo] = [
        RiskyInfo(
            item: .spotlight, title: "Spotlight indexing off",
            does: "Stops Spotlight indexing on every disk (mdutil -a -i off), so it never re-indexes in the background.",
            breaks:
                "Spotlight stops finding new or changed files, and Mail and Finder search get worse. macx's Apps page uses Spotlight for last-used dates. Turning it back on re-indexes everything, which runs hot for a while.",
            undoable: true),
        RiskyInfo(
            item: .hibernation, title: "Hibernation off",
            does: "Sets hibernatemode 0 and deletes the sleep image, freeing its disk space.",
            breaks: "If the battery runs flat while the Mac sleeps, open work that wasn't saved is lost.", undoable: true),
        RiskyInfo(
            item: .powerNap, title: "Power Nap off",
            does: "Sets powernap 0: the Mac does nothing while it sleeps, so it wakes cooler with more battery.",
            breaks: "Mail, iCloud, Find My updates and Time Machine backups don't happen during sleep.", undoable: true),
        RiskyInfo(
            item: .snapshots, title: "Purge Time Machine local snapshots",
            does: "Deletes Time Machine's local snapshots (com.apple.TimeMachine.*). macOS update snapshots are never touched.",
            breaks: "The hourly local versions are gone for good: you can't go back to them.", undoable: false),
    ]

    public static func info(_ item: RiskyItem) -> RiskyInfo { catalog.first { $0.item == item }! }

    /// The sleep image's size (what turning hibernation off frees), if there is one.
    public static func sleepImageBytes() -> UInt64? {
        var st = stat()
        return stat(sleepImage, &st) == 0 ? UInt64(st.st_size) : nil
    }

    /// The line `macx risky` and the app show for an item's state right now.
    public static func state(_ item: RiskyItem, ledger: RiskyLedger, runner: CommandRunner = ProcessRunner(timeout: 20)) -> String {
        if item == .snapshots {
            let n = timeMachineSnapshots((try? runner.run(tmutil, ["listlocalsnapshots", "/"])) ?? "").count
            return n == 0 ? "nothing to purge" : "\(n) snapshot\(n == 1 ? "" : "s")"
        }
        if ledger.before[item.rawValue] != nil { return "changed by macx" }
        return isApplied(item, runner: runner) ? "already like this" : "not changed"
    }

    /// The confirmation word is the item's own name, typed.
    public static func confirms(_ item: RiskyItem, typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == item.rawValue
    }

    /// One `pmset -g custom` setting per power source: "b" battery, "c" AC (charger), "u" UPS.
    public static func pmsetValues(_ custom: String, key: String) -> [String: String] {
        var out: [String: String] = [:]
        var source: String?
        for raw in custom.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                source = line.hasPrefix("Battery") ? "b" : line.hasPrefix("AC") ? "c" : line.hasPrefix("UPS") ? "u" : nil
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if let source, parts.count >= 2, parts[0] == key { out[source] = String(parts[parts.count - 1]) }
        }
        return out
    }

    public static func spotlightOn(_ status: String) -> Bool { status.contains("Indexing enabled") }

    /// Dates of Time Machine's own local snapshots; anything else (macOS update snapshots) is left out.
    public static func timeMachineSnapshots(_ list: String) -> [String] {
        list.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("com.apple.TimeMachine."), l.hasSuffix(".local") else { return nil }
            return String(l.dropFirst("com.apple.TimeMachine.".count).dropLast(".local".count))
        }
    }

    static func pmsetKey(_ item: RiskyItem) -> String { item == .hibernation ? "hibernatemode" : "powernap" }

    /// Whether the item is in its risky state right now.
    public static func isApplied(_ item: RiskyItem, runner: CommandRunner = ProcessRunner(timeout: 20)) -> Bool {
        switch item {
        case .spotlight: return !spotlightOn((try? runner.run(mdutil, ["-s", "/"])) ?? "Indexing enabled")
        case .hibernation, .powerNap:
            let v = pmsetValues((try? runner.run(pmset, ["-g", "custom"])) ?? "", key: pmsetKey(item))
            return !v.isEmpty && v.values.allSatisfy { $0 == "0" }
        case .snapshots: return timeMachineSnapshots((try? runner.run(tmutil, ["listlocalsnapshots", "/"])) ?? "").isEmpty
        }
    }

    /// Stores the before-values (only the first time, so applying twice keeps the original), then changes the setting.
    public static func apply(
        _ item: RiskyItem, ledger: inout RiskyLedger, runner: CommandRunner = ProcessRunner(timeout: 120),
        removeFile: (String) -> Void = { try? FileManager.default.removeItem(atPath: $0) }
    ) throws {
        func run(_ exe: String, _ args: [String]) throws {
            do { _ = try runner.run(exe, args) } catch {
                throw RiskyError.failed("\(([exe] + args).joined(separator: " ")) failed: \(error)")
            }
        }
        switch item {
        case .spotlight:
            if ledger.before[item.rawValue] == nil {
                ledger.before[item.rawValue] = ["/": spotlightOn((try? runner.run(mdutil, ["-s", "/"])) ?? "") ? "on" : "off"]
            }
            try run(mdutil, ["-a", "-i", "off"])
        case .hibernation, .powerNap:
            let key = pmsetKey(item)
            let now = pmsetValues(try runner.run(pmset, ["-g", "custom"]), key: key)
            guard !now.isEmpty else { throw RiskyError.failed("pmset didn't report \(key).") }
            if ledger.before[item.rawValue] == nil { ledger.before[item.rawValue] = now }
            for source in now.keys.sorted() { try run(pmset, ["-\(source)", key, "0"]) }
            if item == .hibernation { removeFile(sleepImage) }
        case .snapshots:
            for date in timeMachineSnapshots(try runner.run(tmutil, ["listlocalsnapshots", "/"])) {
                try run(tmutil, ["deletelocalsnapshots", date])
            }
        }
    }

    public static func undo(_ item: RiskyItem, ledger: inout RiskyLedger, runner: CommandRunner = ProcessRunner(timeout: 120)) throws {
        guard info(item).undoable else { throw RiskyError.notUndoable(info(item).title) }
        guard let before = ledger.before[item.rawValue] else { throw RiskyError.nothingStored(info(item).title) }
        switch item {
        case .spotlight:
            if before["/"] == "on" { _ = try runner.run(mdutil, ["-a", "-i", "on"]) }
        case .hibernation, .powerNap:
            for (source, value) in before.sorted(by: { $0.key < $1.key }) {
                _ = try runner.run(pmset, ["-\(source)", pmsetKey(item), value])
            }
        case .snapshots: break
        }
        ledger.before[item.rawValue] = nil
    }

    /// A shell script that puts every stored value back, for when macx itself can't run.
    public static func undoScript(_ ledger: RiskyLedger) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = ["#!/bin/sh", "# Written by macx risky: puts back what the Risky tier changed. Run with sudo.", "set -e"]
        for (key, before) in ledger.before.sorted(by: { $0.key < $1.key }) {
            switch RiskyItem(rawValue: key) {
            case .spotlight: if before["/"] == "on" { lines.append("\(mdutil) -a -i on") }
            case .hibernation, .powerNap:
                let item = RiskyItem(rawValue: key)!
                for (source, value) in before.sorted(by: { $0.key < $1.key }) {
                    guard ["b", "c", "u"].contains(source) else { continue }
                    lines.append("\(pmset) -\(source) \(pmsetKey(item)) \(q(value))")
                }
            default: continue
            }
        }
        lines.append("rm -f \(q(RiskyLedger.file.path))")
        return lines.joined(separator: "\n") + "\n"
    }
}
