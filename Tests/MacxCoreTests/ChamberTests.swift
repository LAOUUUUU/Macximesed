import Foundation
import Testing

@testable import MacxCore

/// One eslogger line, as the guest agent writes it (the same JSON as the live watch, plus `time`).
func chamberLine(_ name: String, pid: Int, ppid: Int = 1, path: String, body: String, time: String = "2026-11-24T10:00:00.000000000Z")
    -> String
{
    let process = proc(path, pid: pid, ppid: ppid, platform: path.hasPrefix("/usr/") || path.hasPrefix("/bin/"))
    return #"{"schema_version":1,"version":8,"time":"\#(time)","event_type":9,"process":\#(process),"event":{"\#(name)":\#(body)}}"#
}

func openBody(_ path: String) -> String { #"{"fflag":1,"file":{"path":"\#(path)","path_truncated":false}}"# }
func createBody(_ path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    return #"{"destination_type":1,"destination":{"new_path":{"dir":{"path":"\#(dir)"},"filename":"\#(name)"}}}"#
}

@Suite("Detonation chamber: judging the guest's log")
struct ChamberJudgeTests {
    let judge = ChamberJudge(guestHome: URL(fileURLWithPath: "/Users/chamber"))
    let sample = 500

    func report(_ lines: [String]) -> ChamberReport {
        judge.judge(log: Data(lines.joined(separator: "\n").utf8), samplePID: sample)
    }

    @Test func emptyLogIsNothingSeenNeverSafe() {
        let r = report([])
        #expect(r.verdict == .nothingSeen)
        #expect(r.summary.contains("not the same as safe"))
    }

    @Test func fakeAppleLaunchDaemonIsDangerous() {
        let r = report([
            chamberLine(
                "create", pid: sample, path: "/private/tmp/sample", body: createBody("/Library/LaunchDaemons/com.apple.accountsd.plist"))
        ])
        #expect(r.verdict == .dangerous)
    }

    @Test func keychainReadIsCritical() {
        let r = report([
            chamberLine(
                "open", pid: sample, path: "/private/tmp/sample", body: openBody("/Users/chamber/Library/Keychains/login.keychain-db"))
        ])
        #expect(r.alerts.contains { $0.rule == "reads-keychain" && $0.severity == .critical })
        #expect(r.verdict == .dangerous)
    }

    @Test func browserAndWalletReads() {
        let r = report([
            chamberLine(
                "open", pid: sample, path: "/private/tmp/sample",
                body: openBody("/Users/chamber/Library/Application Support/Google/Chrome/Default/Login Data")),
            chamberLine(
                "open", pid: sample, path: "/private/tmp/sample",
                body: openBody("/Users/chamber/Library/Application Support/Exodus/exodus.wallet/seed.seco")),
        ])
        #expect(r.alerts.contains { $0.rule == "reads-browser-data" && $0.severity == .high })
        #expect(r.alerts.contains { $0.rule == "reads-wallet" && $0.severity == .high })
        // Two different high rules make it dangerous.
        #expect(r.verdict == .dangerous)
    }

    @Test func oneHighIsCaution() {
        let r = report([
            chamberLine(
                "open", pid: sample, path: "/private/tmp/sample",
                body: openBody("/Users/chamber/Library/Application Support/Firefox/Profiles/x/logins.json"))
        ])
        #expect(r.verdict == .caution)
    }

    @Test func onlyTheSamplesOwnTreeCounts() {
        // macOS's own daemons open keychains all the time; that's not the sample.
        let r = report([
            chamberLine(
                "open", pid: 88, path: "/usr/libexec/securityd", body: openBody("/Users/chamber/Library/Keychains/login.keychain-db"))
        ])
        #expect(r.alerts.isEmpty)
        #expect(r.verdict == .nothingSeen)
    }

    @Test func childrenOfTheSampleCount() {
        let exec = #"{"target":\#(proc("/bin/zsh", pid: 501, ppid: 500, platform: true)),"args":["zsh","-c","true"]}"#
        let r = report([
            chamberLine("exec", pid: sample, path: "/private/tmp/sample", body: exec),
            chamberLine(
                "open", pid: 501, ppid: 500, path: "/bin/zsh", body: openBody("/Users/chamber/Library/Keychains/login.keychain-db")),
        ])
        #expect(r.alerts.contains { $0.rule == "reads-keychain" })
    }

    @Test func vmCheckThenQuit() {
        let check =
            #"{"target":\#(proc("/usr/sbin/system_profiler", pid: 502, ppid: 500, platform: true)),"args":["sh","-c","system_profiler SPHardwareDataType | grep -i 'Apple Virtual Machine'"]}"#
        let r = report([
            chamberLine("exec", pid: sample, path: "/private/tmp/sample", body: check, time: "2026-11-24T10:00:01.000000000Z"),
            chamberLine("exit", pid: sample, path: "/private/tmp/sample", body: #"{"stat":0}"#, time: "2026-11-24T10:00:04.000000000Z"),
        ])
        #expect(r.alerts.contains { $0.rule == "vm-check" })
        #expect(r.alerts.contains { $0.rule == "vm-check-then-quit" && $0.severity == .high })
        #expect(r.summary.contains("virtual machine"))
    }

    @Test func vmCheckWithoutQuittingIsNotThenQuit() {
        let check =
            #"{"target":\#(proc("/usr/sbin/system_profiler", pid: 502, ppid: 500, platform: true)),"args":["sh","-c","system_profiler SPHardwareDataType | grep -i VMware"]}"#
        let r = report([
            chamberLine("exec", pid: sample, path: "/private/tmp/sample", body: check, time: "2026-11-24T10:00:01.000000000Z"),
            chamberLine("exit", pid: sample, path: "/private/tmp/sample", body: #"{"stat":0}"#, time: "2026-11-24T10:00:30.000000000Z"),
        ])
        #expect(!r.alerts.contains { $0.rule == "vm-check-then-quit" })
    }
}

@Suite("Detonation chamber: the guest's log is untrusted")
struct ChamberLogTests {
    @Test func skipsJunkAndOversizedLines() {
        let good = chamberLine("exit", pid: 5, path: "/bin/sh", body: #"{"stat":0}"#)
        let huge = String(repeating: "a", count: 70_000)
        let parsed = ChamberLog.parse(Data([good, "not json", huge, good].joined(separator: "\n").utf8))
        #expect(parsed.events.count == 2)
        #expect(parsed.skipped == 2)
        #expect(!parsed.truncated)
    }

    @Test func capsTheWholeLog() {
        let good = chamberLine("exit", pid: 5, path: "/bin/sh", body: #"{"stat":0}"#)
        let lines = Array(repeating: good, count: 1000).joined(separator: "\n")
        let parsed = ChamberLog.parse(Data(lines.utf8), maxBytes: 10_000)
        #expect(parsed.truncated)
        #expect(parsed.events.count < 1000)
    }

    @Test func readsTimeAndOpenAndExit() throws {
        let parsed = ChamberLog.parse(
            Data(
                [
                    chamberLine("open", pid: 5, path: "/bin/cat", body: openBody("/etc/hosts"), time: "2026-11-24T10:00:01.250000000Z"),
                    chamberLine("exit", pid: 5, path: "/bin/cat", body: #"{"stat":0}"#),
                ].joined(separator: "\n").utf8))
        let open = try #require(parsed.events.first)
        #expect(open.kind == "open")
        #expect(open.filePath == "/etc/hosts")
        let t = try #require(open.time)
        #expect(abs(t.timeIntervalSince1970 - 1_795_514_401.25) < 0.001)
        #expect(parsed.events.last?.kind == "exit")
    }
}

@Suite("Detonation chamber: sample pinning and quarantine")
struct ChamberQuarantineTests {
    @Test func changedSampleIsRefused() throws {
        let tmp = try TempDir()
        let f = try tmp.file("Downloads/installer.sh", "echo one")
        let pinned = try ChamberSample(pinning: f)
        #expect(throws: Never.self) { try pinned.verifyUnchanged() }
        try Data("echo two".utf8).write(to: f)
        #expect(throws: ChamberSample.Problem.changed) { try pinned.verifyUnchanged() }
    }

    @Test func dangerousSampleIsQuarantinedAndRestorable() throws {
        let tmp = try TempDir()
        let f = try tmp.file("Downloads/Installer.app.zip", "evil bytes")
        let sample = try ChamberSample(pinning: f)
        let judge = ChamberJudge(guestHome: URL(fileURLWithPath: "/Users/chamber"))
        let report = judge.judge(
            log: Data(
                chamberLine("open", pid: 500, path: "/private/tmp/x", body: openBody("/Users/chamber/Library/Keychains/login.keychain-db"))
                    .utf8),
            samplePID: 500)
        #expect(report.verdict == .dangerous)

        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        let q = ChamberQuarantine(recorder: IncidentRecorder(root: tmp.url.appendingPathComponent("cases")), store: store)
        let (incident, batch) = try q.quarantine(sample, report: report)

        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(incident.evidence.contains { $0.sha256 == sample.sha256 })
        #expect(incident.trigger.rule == "chamber-dangerous")
        _ = try store.restore(id: batch.id)
        #expect(try String(contentsOf: f, encoding: .utf8) == "evil bytes")
    }

    @Test func refusesToQuarantineAChangedFile() throws {
        let tmp = try TempDir()
        let f = try tmp.file("Downloads/a.sh", "one")
        let sample = try ChamberSample(pinning: f)
        try Data("two".utf8).write(to: f)
        let q = ChamberQuarantine(
            recorder: IncidentRecorder(root: tmp.url.appendingPathComponent("cases")),
            store: UndoStore(root: tmp.url.appendingPathComponent("undo")))
        let report = ChamberReport(verdict: .dangerous, alerts: [], summary: "", skipped: 0, truncated: false)
        #expect(throws: ChamberSample.Problem.changed) { try q.quarantine(sample, report: report) }
    }
}
