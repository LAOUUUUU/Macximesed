import Foundation
import Testing

@testable import MacxCore

@Suite("Incident case folder")
struct IncidentCaseTests {
    func setup() throws -> (TempDir, IncidentRecorder, [ProcessTree.Entry]) {
        let tmp = try TempDir()
        let payload = try tmp.file("home/Library/Application Support/.com.apple.accountsd/AccountsHelper", "evil payload bytes")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path)
        try tmp.plist("sys/Library/LaunchDaemons/com.apple.accountsd.helper.plist", amosLoader())
        let table: [ProcessTree.Entry] = [
            .init(pid: 1, ppid: 0, path: "/sbin/launchd"),
            .init(pid: 700, ppid: 1, path: "/bin/bash"),
            .init(pid: 701, ppid: 700, path: payload.path),
        ]
        let recorder = IncidentRecorder(
            root: tmp.url.appendingPathComponent("cases"), maxFileBytes: 1_000_000, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return (tmp, recorder, table)
    }

    @Test func recordsEvidenceWithHashesTreeAndSummary() throws {
        let (tmp, recorder, table) = try setup()
        let plist = tmp.url.appendingPathComponent("sys/Library/LaunchDaemons/com.apple.accountsd.helper.plist")
        let c = try recorder.record(
            trigger: IncidentTrigger(
                rule: "fake-apple-launch-item", severity: .critical, title: "Apple-named launch item", detail: plist.path),
            pid: 701, processTable: table, files: [plist], frozen: [701], timeline: ["{\"rule\":\"base64-to-shell\"}"])

        // Private folder.
        let perms = try FileManager.default.attributesOfItem(atPath: c.folder.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)

        // Both the named file and every program in the process chain are copied, hashed and left non-executable.
        let names = Set(c.evidence.map { URL(fileURLWithPath: $0.originalPath).lastPathComponent })
        #expect(names.isSuperset(of: ["com.apple.accountsd.helper.plist", "AccountsHelper"]))
        for e in c.evidence where e.copied {
            let copy = c.folder.appendingPathComponent(e.copyName!)
            #expect(sha256(try Data(contentsOf: copy)) == e.sha256)
            #expect(!FileManager.default.isExecutableFile(atPath: copy.path))
        }
        let payload = try #require(c.evidence.first { $0.originalPath.hasSuffix("AccountsHelper") })
        #expect(payload.mode == 0o755)  // the original's mode is recorded

        // Tree: who started it.
        #expect(c.ancestry.map(\.pid) == [701, 700, 1])
        #expect(c.frozen == [701])

        // Files a person can read, and the machine-readable record.
        for f in ["summary.md", "case.json", "timeline.jsonl"] {
            #expect(FileManager.default.fileExists(atPath: c.folder.appendingPathComponent(f).path), "\(f)")
        }
        let summary = try String(contentsOf: c.folder.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary.contains("fake-apple-launch-item"))
        #expect(summary.contains(payload.sha256))
    }

    @Test func bigOrUnreadableFilesAreHashedOrNotedNotCopied() throws {
        let (tmp, _, table) = try setup()
        let big = try tmp.file("big.bin", String(repeating: "x", count: 5000))
        let small = IncidentRecorder(root: tmp.url.appendingPathComponent("cases2"), maxFileBytes: 1000, now: Date.init)
        let c = try small.record(
            trigger: IncidentTrigger(rule: "r", severity: .high, title: "t", detail: nil), pid: nil, processTable: table,
            files: [big, tmp.url.appendingPathComponent("missing")], frozen: [], timeline: [])
        let b = try #require(c.evidence.first { $0.originalPath == big.path })
        #expect(!b.copied)
        #expect(b.sha256 == sha256(try Data(contentsOf: big)))
        #expect(c.evidence.first { $0.originalPath.hasSuffix("missing") }?.note == "missing")
    }

    @Test func casesAreListedNewestFirst() throws {
        let (_, recorder, table) = try setup()
        let early = IncidentRecorder(root: recorder.root, maxFileBytes: 1000, now: { Date(timeIntervalSince1970: 1_800_000_060) })
        let late = IncidentRecorder(root: recorder.root, maxFileBytes: 1000, now: { Date(timeIntervalSince1970: 1_800_000_120) })
        let r = late
        let a = try early.record(
            trigger: IncidentTrigger(rule: "a", severity: .high, title: "a", detail: nil), pid: nil, processTable: table, files: [],
            frozen: [], timeline: [])
        let b = try late.record(
            trigger: IncidentTrigger(rule: "b", severity: .high, title: "b", detail: nil), pid: nil, processTable: table, files: [],
            frozen: [], timeline: [])
        #expect(try r.list().map(\.id) == [b.id, a.id])
        #expect(try r.load(id: a.id).trigger.rule == "a")
    }
}

@Suite("Incident containment")
struct IncidentContainTests {
    @Test func movesPersistenceIntoTheUndoStoreAndCanBeRestored() throws {
        let tmp = try TempDir()
        let plist = try tmp.plist("home/Library/LaunchAgents/com.apple.fake.plist", ["Label": "com.apple.fake"])
        let folder = try tmp.file("home/Library/Application Support/.com.apple.fake/run", "x").deletingLastPathComponent()
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        let plan = IncidentContainment.plan(paths: [plist, folder, URL(fileURLWithPath: "/System/Library/LaunchDaemons/com.apple.x.plist")])
        #expect(plan.toMove.count == 2)
        #expect(plan.refused.count == 1)  // never anything on the system volume

        let batch = try IncidentContainment.run(plan, store: store, caseID: "case-1")
        #expect(!tmp.exists("home/Library/LaunchAgents/com.apple.fake.plist"))
        #expect(!tmp.exists("home/Library/Application Support/.com.apple.fake"))
        #expect(batch.reason.contains("case-1"))
        _ = try store.restore(id: batch.id)
        #expect(tmp.exists("home/Library/LaunchAgents/com.apple.fake.plist"))
    }

    @Test func launchItemLabelsGetBootoutCommands() throws {
        let tmp = try TempDir()
        let agent = try tmp.plist("home/Library/LaunchAgents/com.x.agent.plist", ["Label": "com.x.agent"])
        let daemon = try tmp.plist("sys/Library/LaunchDaemons/com.x.daemon.plist", ["Label": "com.x.daemon"])
        let cmds = IncidentContainment.bootoutCommands(for: [agent, daemon], uid: 501)
        #expect(cmds.contains("launchctl bootout gui/501/com.x.agent"))
        #expect(cmds.contains("sudo launchctl bootout system/com.x.daemon"))
    }
}

@Suite("Folders the root watch creates in your home belong to you")
struct HandOverParentsTests {
    @Test func everyRootOwnedFolderBetweenHomeAndTheNewOneIsHandedOver() {
        let home = URL(fileURLWithPath: "/Users/v")
        let made = home.appendingPathComponent("Library/Application Support/Macximesed/Cases/2026-x")
        // Library and Application Support already belong to the user; Macximesed and Cases were just made by root.
        let owners: [String: uid_t] = [
            "/Users/v/Library": 501, "/Users/v/Library/Application Support": 501,
            "/Users/v/Library/Application Support/Macximesed": 0, "/Users/v/Library/Application Support/Macximesed/Cases": 0,
            "/Users/v/Library/Application Support/Macximesed/Cases/2026-x": 0,
        ]
        let paths = HomeOwnership.rootOwnedFolders(upTo: made, home: home) { owners[$0] }
        #expect(
            paths == [
                "/Users/v/Library/Application Support/Macximesed", "/Users/v/Library/Application Support/Macximesed/Cases",
                "/Users/v/Library/Application Support/Macximesed/Cases/2026-x",
            ])
    }

    @Test func nothingOutsideTheHomeFolderOrTheHomeItself() {
        let home = URL(fileURLWithPath: "/Users/v")
        #expect(HomeOwnership.rootOwnedFolders(upTo: URL(fileURLWithPath: "/Library/X"), home: home) { _ in 0 }.isEmpty)
        #expect(HomeOwnership.rootOwnedFolders(upTo: home, home: home) { _ in 0 }.isEmpty)
        #expect(HomeOwnership.rootOwnedFolders(upTo: URL(fileURLWithPath: "/Users/vv/a"), home: home) { _ in 0 }.isEmpty)
    }
}
