import Darwin
import Foundation

/// The background watch's Downloads check: every finished download gets the full `macx check`, and anything
/// judged DON'T OPEN THIS is quarantined (a case folder plus the undo store, restorable) before it can be opened.
/// Spec: research/downloads-watch/RESEARCH.md.
public enum DownloadWatch {
    /// What browsers call a download in progress: Safari, Chrome, Firefox.
    static let tempSuffixes = [".download", ".crdownload", ".part"]

    static func isTemp(_ name: String) -> Bool { tempSuffixes.contains { name.hasSuffix($0) } }

    /// The finished download an event announces, if any:
    /// - a rename into Downloads from a browser's temp name (or out of Safari's `.download` folder), or from
    ///   outside Downloads (a file moved in);
    /// - a file created directly in Downloads under its final name (curl -o, AirDrop, Mail).
    /// Never temp names, hidden files, or anything in a subfolder (an unpacked archive isn't a new download).
    public static func finishedDownload(_ e: ESEvent, downloads: String) -> String? {
        guard e.kind == "create" || e.kind == "rename", let path = e.filePath else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard dir == downloads, !name.hasPrefix("."), !isTemp(name) else { return nil }
        if e.kind == "rename", let src = e.sourcePath {
            let srcDir = (src as NSString).deletingLastPathComponent
            let fromBrowser = isTemp((src as NSString).lastPathComponent) || srcDir.hasSuffix(".download")
            let fromOutside = srcDir != downloads && !srcDir.hasPrefix(downloads + "/")
            guard fromBrowser || fromOutside else { return nil }  // the user renaming a file they already had
        }
        return path
    }

    /// The worst verdict in the report, including what's inside a disk image or folder.
    static func worst(_ r: FileReport) -> Verdict { r.inner.map(worst).reduce(r.verdict) { max($0, $1) } }

    static func findings(_ r: FileReport) -> [CheckFinding] { r.findings + r.inner.flatMap(findings) }

    public static func alert(for r: FileReport) -> WatchAlert {
        let name = r.path.lastPathComponent
        let reasons = findings(r).sorted { $0.severity > $1.severity }.prefix(3).map(\.title)
        let detail = ([r.path.path] + reasons).joined(separator: "\n  ")
        switch worst(r) {
        case .dangerous:
            return WatchAlert(
                rule: "download-dangerous", severity: .critical, title: "Dangerous download: \(name)", detail: detail, pid: nil,
                processPath: nil)
        case .caution, .partlyUnknown:
            return WatchAlert(
                rule: "download-caution", severity: .medium, title: "Download needs care: \(name)", detail: detail, pid: nil,
                processPath: nil)
        case .ok:
            return WatchAlert(
                rule: "download-ok", severity: .info, title: "Download checked: \(name)", detail: r.path.path, pid: nil, processPath: nil)
        }
    }

    public struct Quarantined: Sendable {
        public var caseID: String
        public var batchID: String
    }

    static func support(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Macximesed") }

    /// Into a case folder and the user's undo store (`macx undo restore BATCH` brings it back). The background watch
    /// runs as root, so everything it makes is handed to the user (`owner`).
    public static func quarantine(_ file: URL, report: FileReport, home: URL, owner: (uid: uid_t, gid: gid_t)?) throws -> Quarantined {
        let trigger = IncidentTrigger(
            rule: "download-dangerous", severity: .critical, title: "Dangerous download: \(file.lastPathComponent)",
            detail: findings(report).prefix(5).map(\.title).joined(separator: "; "))
        let recorder = IncidentRecorder(root: support(home).appendingPathComponent("Cases"))
        let incident = try recorder.record(trigger: trigger, pid: nil, processTable: [], files: [file], frozen: [], timeline: [])
        let store = UndoStore(root: support(home).appendingPathComponent("Undo"))
        let batch = try IncidentContainment.run(IncidentContainment.plan(paths: [file]), store: store, caseID: incident.id)
        if let owner {
            for dir in [support(home).appendingPathComponent("Cases"), support(home).appendingPathComponent("Undo")] {
                chownTree(dir, owner)
                HomeOwnership.handOverParents(of: dir, home: home, uid: owner.uid, gid: owner.gid)
            }
        }
        return Quarantined(caseID: incident.id, batchID: batch.id)
    }

    static func chownTree(_ dir: URL, _ owner: (uid: uid_t, gid: gid_t)) {
        chown(dir.path, owner.uid, owner.gid)
        guard let walker = FileManager.default.enumerator(atPath: dir.path) else { return }
        for case let rel as String in walker { lchown(dir.appendingPathComponent(rel).path, owner.uid, owner.gid) }
    }

    // MARK: Files the user restored are allowed

    static func allowFile(_ home: URL) -> URL { support(home).appendingPathComponent("download-allow.json") }

    static func allowed(home: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: allowFile(home)), let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    public static func isAllowed(_ sha: String, home: URL) -> Bool { allowed(home: home).contains(sha.lowercased()) }

    /// After `macx undo restore` of a quarantined download: the user decided that exact file is fine, so the watch
    /// won't quarantine it again when it lands back in Downloads.
    public static func allowRestored(_ batch: UndoBatch, home: URL) {
        guard batch.reason.contains("download-dangerous") else { return }
        var set = allowed(home: home)
        for item in batch.items {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: item.originalPath)) { set.insert(sha256(data)) }
        }
        try? FileManager.default.createDirectory(at: support(home), withIntermediateDirectories: true)
        try? JSONEncoder().encode(set.sorted()).write(to: allowFile(home), options: .atomic)
    }

    /// Waits until a file stops growing (some apps write after the final rename), up to `timeout`.
    public static func waitUntilSettled(_ file: URL, interval: TimeInterval = 1, timeout: TimeInterval = 20) {
        var last: UInt64?
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? nil
            if let size, size == last { return }
            last = size
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
