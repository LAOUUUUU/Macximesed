import Foundation

// MARK: - Records

public struct IncidentTrigger: Codable, Sendable, Equatable {
    public var rule: String
    public var severity: Severity
    public var title: String
    public var detail: String?

    public init(rule: String, severity: Severity, title: String, detail: String?) {
        self.rule = rule
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

/// One file kept as evidence: its hash and details always, a copy when it's small enough to keep.
public struct EvidenceFile: Codable, Sendable, Equatable {
    public var originalPath: String
    /// Empty when the file was missing or unreadable.
    public var sha256: String
    public var bytes: UInt64
    public var mode: Int?
    public var owner: Int?
    public var modified: Date?
    public var copied: Bool
    /// Inside the case folder, when copied.
    public var copyName: String?
    public var note: String?
}

public struct IncidentCase: Codable, Sendable {
    public var id: String
    public var created: Date
    public var trigger: IncidentTrigger
    public var pid: Int?
    /// The process, its parent, and so on up to launchd.
    public var ancestry: [ProcessTree.Entry]
    public var descendants: [ProcessTree.Entry]
    public var frozen: [Int]
    public var evidence: [EvidenceFile]
    /// Where the case lives. Not stored in case.json (it's the folder case.json is in).
    public var folder: URL = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey { case id, created, trigger, pid, ancestry, descendants, frozen, evidence }
}

// MARK: - Recording

/// Keeps what an investigation needs before anything is cleaned up: copies and hashes of the files
/// involved, the process tree, the alert timeline, and a summary a person can read. Each case is a
/// private folder (0700); copies are read-only and never executable.
public struct IncidentRecorder: Sendable {
    public var root: URL
    public var maxFileBytes: UInt64
    var now: @Sendable () -> Date

    public init(
        root: URL = IncidentRecorder.defaultRoot, maxFileBytes: UInt64 = 50_000_000, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = root
        self.maxFileBytes = maxFileBytes
        self.now = now
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Macximesed/Cases")
    }

    /// Programs under these folders are Apple's own; they're named in the tree but not copied.
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    public func record(
        trigger: IncidentTrigger, pid: Int?, processTable: [ProcessTree.Entry], files: [URL], frozen: [Int],
        timeline: [String]
    ) throws -> IncidentCase {
        let fm = FileManager.default
        let created = now()
        let id = Self.makeID(created, rule: trigger.rule)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let evidenceDir = folder.appendingPathComponent("evidence", isDirectory: true)
        try fm.createDirectory(at: evidenceDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let ancestry = pid.map { ProcessTree.ancestry(of: $0, in: processTable) } ?? []
        let descendants =
            pid.map { p in ProcessTree.descendants(of: p, in: processTable).compactMap { d in processTable.first { $0.pid == d } } } ?? []

        // The named files, plus every non-Apple program in the process chain, without repeats.
        var paths: [URL] = []
        func want(_ u: URL) { if !paths.contains(u.standardizedFileURL) { paths.append(u.standardizedFileURL) } }
        files.forEach(want)
        for e in ancestry + descendants where !e.path.isEmpty && !Self.systemPrefixes.contains(where: { e.path.hasPrefix($0) }) {
            want(URL(fileURLWithPath: e.path))
        }
        // A folder (like a hidden payload folder) counts as the files in it.
        var expanded: [URL] = []
        for p in paths {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue {
                let walker = fm.enumerator(at: p, includingPropertiesForKeys: [.isRegularFileKey])
                var n = 0
                while let f = walker?.nextObject() as? URL, n < 50 {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        expanded.append(f)
                        n += 1
                    }
                }
            } else {
                expanded.append(p)
            }
        }

        var evidence: [EvidenceFile] = []
        for (i, f) in expanded.enumerated() {
            evidence.append(keep(f, index: i, into: evidenceDir))
        }

        var c = IncidentCase(
            id: id, created: created, trigger: trigger, pid: pid, ancestry: ancestry, descendants: descendants,
            frozen: frozen, evidence: evidence)
        c.folder = folder
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(try enc.encode(c), to: folder.appendingPathComponent("case.json"))
        try write(
            Data((timeline.joined(separator: "\n") + (timeline.isEmpty ? "" : "\n")).utf8),
            to: folder.appendingPathComponent("timeline.jsonl"))
        try write(Data(Self.summary(c).utf8), to: folder.appendingPathComponent("summary.md"))
        return c
    }

    func keep(_ f: URL, index: Int, into dir: URL) -> EvidenceFile {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: f.path) else {
            return EvidenceFile(originalPath: f.path, sha256: "", bytes: 0, copied: false, note: "missing")
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        var e = EvidenceFile(
            originalPath: f.path, sha256: "", bytes: size, mode: (attrs[.posixPermissions] as? NSNumber)?.intValue,
            owner: (attrs[.ownerAccountID] as? NSNumber)?.intValue, modified: attrs[.modificationDate] as? Date, copied: false)
        guard fm.isReadableFile(atPath: f.path), let hash = FileChecker.hashFile(f) else {
            e.note = "not readable (root only, or a privacy-guarded folder)"
            return e
        }
        e.sha256 = hash
        guard size <= maxFileBytes else {
            e.note = "too big to copy (\(formatBytes(size))); hash kept"
            return e
        }
        let name = "\(index)-\(f.lastPathComponent)"
        let copy = dir.appendingPathComponent(name)
        if (try? fm.copyItem(at: f, to: copy)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.path)
            e.copied = true
            e.copyName = "evidence/\(name)"
        } else {
            e.note = "couldn't copy; hash kept"
        }
        return e
    }

    func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func list() throws -> [IncidentCase] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { try? load(id: $0) }.sorted { $0.created > $1.created }
    }

    public func load(id: String) throws -> IncidentCase {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var c = try dec.decode(IncidentCase.self, from: Data(contentsOf: folder.appendingPathComponent("case.json")))
        c.folder = folder
        return c
    }

    static func makeID(_ date: Date, rule: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safeRule = rule.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(f.string(from: date))-\(safeRule)-\(UUID().uuidString.prefix(4).lowercased())"
    }

    static func summary(_ c: IncidentCase) -> String {
        var s = "# Incident \(c.id)\n\n"
        s += "- **When:** \(ISO8601DateFormatter().string(from: c.created))\n"
        s += "- **What:** \(c.trigger.title) (`\(c.trigger.rule)`, \(c.trigger.severity.label))\n"
        if let d = c.trigger.detail { s += "- **Detail:** \(d)\n" }
        if !c.frozen.isEmpty { s += "- **Frozen processes:** \(c.frozen.map(String.init).joined(separator: ", "))\n" }
        if !c.ancestry.isEmpty {
            s += "\n## Who started it\n\n"
            for e in c.ancestry { s += "- \(e.pid): \(e.path.isEmpty ? "(unknown)" : e.path)\n" }
        }
        if !c.descendants.isEmpty {
            s += "\n## What it started\n\n"
            for e in c.descendants { s += "- \(e.pid): \(e.path)\n" }
        }
        s += "\n## Evidence\n\n| File | SHA-256 | Size | Kept |\n|---|---|---|---|\n"
        for e in c.evidence {
            s +=
                "| `\(e.originalPath)` | `\(e.sha256.isEmpty ? "-" : e.sha256)` | \(formatBytes(e.bytes)) | \(e.copied ? e.copyName ?? "yes" : e.note ?? "no") |\n"
        }
        s += """

            ## What to do now

            1. Don't type your password into any box that appears unexpectedly.
            2. Contain it: `macx incident contain \(c.id)` moves the launch items and hidden folders it found into the undo folder (nothing is deleted).
            3. From a **different, clean device**: change the passwords that were on this Mac (Apple ID, email, banking, password manager), sign out other sessions, and turn on two-factor sign-in.
            4. Replace SSH keys, API keys and tokens that were on this Mac, and revoke the old ones.
            5. If a stealer really ran, back up your files and erase and reinstall macOS. A cleaned Mac can't be fully trusted.

            Copies in `evidence/` are read-only and not executable. Don't open them; share their SHA-256 hashes instead.

            """
        return s
    }
}

// MARK: - Containment

public enum IncidentContainment {
    public struct Plan: Sendable {
        public var toMove: [URL]
        public var refused: [(URL, String)]
    }

    /// What can be moved aside: existing items outside the system volume and Apple's own folders.
    public static func plan(paths: [URL]) -> Plan {
        var move: [URL] = []
        var refused: [(URL, String)] = []
        for p in paths {
            let path = p.standardizedFileURL.path
            if IncidentRecorder.systemPrefixes.contains(where: { path.hasPrefix($0) }) {
                refused.append((p, "part of macOS"))
            } else if !FileManager.default.fileExists(atPath: path) {
                refused.append((p, "already gone"))
            } else if !move.contains(p) {
                move.append(p)
            }
        }
        return Plan(toMove: move, refused: refused)
    }

    public static func run(_ plan: Plan, store: UndoStore, caseID: String) throws -> UndoBatch {
        try store.stash(plan.toMove, reason: "contain \(caseID): " + plan.toMove.map(\.lastPathComponent).joined(separator: ", "))
    }

    /// Commands that stop a launch item that's already loaded (moving the file stops it starting again).
    public static func bootoutCommands(for plists: [URL], uid: uid_t) -> [String] {
        plists.compactMap { url in
            guard url.pathExtension == "plist", let data = try? Data(contentsOf: url),
                let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let label = dict["Label"] as? String
            else { return nil }
            return url.path.contains("/LaunchDaemons/") ? "sudo launchctl bootout system/\(label)" : "launchctl bootout gui/\(uid)/\(label)"
        }
    }
}
