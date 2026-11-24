import Foundation
import Testing

@testable import MacxCore

@Suite("Mac app: launch mode")
struct LaunchModeTests {
    @Test func opensTheAppOnlyWhenLaunchServicesStartedItWithNoArguments() {
        let ls = ["MACX_APP": "1"]
        #expect(LaunchMode.decide(arguments: [], environment: ls) == .app)
        // Old LaunchServices launches add a process serial number argument.
        #expect(LaunchMode.decide(arguments: ["-psn_0_12345"], environment: ls) == .app)
        // A shell run never has MACX_APP (LSEnvironment only applies to LaunchServices launches).
        #expect(LaunchMode.decide(arguments: [], environment: [:]) == .cli)
        // Any real command stays the CLI, even inside the app's environment (the daemon, scripts).
        #expect(LaunchMode.decide(arguments: ["watch", "--background"], environment: ls) == .cli)
        #expect(LaunchMode.decide(arguments: ["--version"], environment: ls) == .cli)
    }

    @Test func macxAppOpensTheAppFromATerminal() {
        #expect(LaunchMode.decide(arguments: ["app"], environment: [:]) == .app)
        #expect(LaunchMode.decide(arguments: ["app", "extra"], environment: [:]) == .cli)
    }
}

@Suite("Mac app: alert groups")
struct AlertGroupTests {
    func record(_ rule: String, _ sev: Severity, _ process: String, at t: Double, title: String = "T", detail: String = "") -> AlertRecord {
        AlertRecord(time: Date(timeIntervalSince1970: t), rule: rule, severity: sev, title: title, detail: detail, process: process)
    }

    @Test func groupsByRuleAndProgramWithCountsAndTimes() {
        let records = [
            record("quarantine-removed", .high, "/usr/bin/xattr", at: 10),
            record("quarantine-removed", .high, "/usr/bin/xattr", at: 30, detail: "latest"),
            record("quarantine-removed", .high, "/bin/cp", at: 20),
            record("base64-to-shell", .critical, "/bin/zsh", at: 5),
            record("frozen", .info, "", at: 6),
        ]
        let groups = AlertGroups.make(records)
        #expect(groups.count == 3)  // "frozen" bookkeeping lines are not alerts
        // Most severe first, then most recent.
        #expect(groups.map(\.rule) == ["base64-to-shell", "quarantine-removed", "quarantine-removed"])
        let xattr = groups[1]
        #expect(xattr.process == "/usr/bin/xattr")
        #expect(xattr.count == 2)
        #expect(xattr.first == Date(timeIntervalSince1970: 10))
        #expect(xattr.last == Date(timeIntervalSince1970: 30))
        #expect(xattr.latest.detail == "latest")
        #expect(groups[2].process == "/bin/cp")
    }

    @Test func groupTakesTheHighestSeverityItSaw() {
        let g = AlertGroups.make([record("r", .medium, "/p", at: 1), record("r", .high, "/p", at: 2), record("r", .low, "/p", at: 3)])
        #expect(g.count == 1)
        #expect(g[0].severity == .high)
    }

    @Test func expectedProgramsHideNonCriticalGroupsButNeverCritical() {
        let records = [
            record("exec-from-hidden-or-temp", .high, "/dev/macx", at: 1), record("base64-to-shell", .critical, "/bin/zsh", at: 2),
        ]
        let expected: Set<String> = ["exec-from-hidden-or-temp|/dev/macx", "base64-to-shell|/bin/zsh"]
        let groups = AlertGroups.make(records, expected: expected)
        #expect(groups.map(\.rule) == ["base64-to-shell"])
        #expect(AlertGroups.canMarkExpected(groups[0]) == false)
        #expect(AlertGroups.canMarkExpected(AlertGroups.make([records[0]])[0]))
    }

    @Test func filterKeepsCriticalAndHighOrAll() {
        let groups = AlertGroups.make([
            record("a", .critical, "/a", at: 1), record("b", .high, "/b", at: 2), record("c", .medium, "/c", at: 3),
        ])
        #expect(AlertGroups.filter(groups, seriousOnly: true).map(\.rule) == ["a", "b"])
        #expect(AlertGroups.filter(groups, seriousOnly: false).count == 3)
    }

    @Test func expectedListRoundTripsAndRefusesCritical() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macx-expected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("expected.json")
        var list = ExpectedPrograms(file: file)
        #expect(list.keys.isEmpty)
        let high = AlertGroups.make([record("r", .high, "/p", at: 1)])[0]
        let crit = AlertGroups.make([record("k", .critical, "/z", at: 1)])[0]
        try list.add(high)
        #expect(throws: ExpectedPrograms.Refused.self) { try list.add(crit) }
        #expect(ExpectedPrograms(file: file).keys == ["r|/p"])
    }
}

@Suite("Mac app: alert log tail")
struct AlertTailTests {
    func line(_ rule: String, _ epoch: Double) -> String {
        #"{"rule":"\#(rule)","severity":"high","title":"T","epoch":\#(epoch),"process":"/p","detail":""}"#
    }

    @Test func readsOnlyNewCompleteLinesAndRestartsAfterTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macx-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var tail = AlertTail(file: file)
        #expect(tail.readNew().isEmpty)  // no file yet

        try (line("a", 1) + "\n" + line("b", 2) + "\n").write(to: file, atomically: false, encoding: .utf8)
        #expect(tail.readNew().map(\.rule) == ["a", "b"])
        #expect(tail.readNew().isEmpty)

        // A half-written line waits until its newline arrives.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line("c", 3).prefix(20).utf8))
        #expect(tail.readNew().isEmpty)
        try h.write(contentsOf: Data((line("c", 3).dropFirst(20) + "\n").utf8))
        try h.close()
        #expect(tail.readNew().map(\.rule) == ["c"])

        // Rotated or cleared: start again from the top.
        try (line("d", 4) + "\n").write(to: file, atomically: false, encoding: .utf8)
        #expect(tail.readNew().map(\.rule) == ["d"])
    }
}

@Suite("Mac app: protection state")
struct WatchStateTests {
    let since = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 2_000)

    @Test func watchingWhenLoadedAndTheDaemonSaysSo() {
        let s = WatchState.derive(
            installed: true, running: true, status: DaemonStatus(state: .watching, message: "", since: since), pausedUntil: nil, now: now)
        #expect(s == .watching(since: since))
        #expect(s.headline == "Watching.")
        #expect(s.glyph == .watching)
    }

    @Test func pausedWinsOverWatchingUntilItExpires() {
        let status = DaemonStatus(state: .watching, message: "", since: since)
        let until = Date(timeIntervalSince1970: 3_000)
        let s = WatchState.derive(installed: true, running: true, status: status, pausedUntil: until, now: now)
        #expect(s == .paused(until: until))
        #expect(s.glyph == .paused)
        let later = WatchState.derive(
            installed: true, running: true, status: status, pausedUntil: until, now: Date(timeIntervalSince1970: 3_001))
        #expect(later == .watching(since: since))
    }

    @Test func notInstalledNotRunningRefusedAndStarting() {
        #expect(WatchState.derive(installed: false, running: false, status: nil, pausedUntil: nil, now: now) == .notInstalled)
        let refused = DaemonStatus(state: .refused, message: "Give Full Disk Access", since: since)
        let r = WatchState.derive(installed: true, running: false, status: refused, pausedUntil: nil, now: now)
        #expect(r == .refused(message: "Give Full Disk Access"))
        #expect(r.glyph == .off)
        // launchd says it isn't running, so an old "watching" in the status file is stale.
        let stale = DaemonStatus(state: .watching, message: "", since: since)
        #expect(WatchState.derive(installed: true, running: false, status: stale, pausedUntil: nil, now: now) == .notRunning)
        let starting = DaemonStatus(state: .starting, message: "", since: since)
        #expect(WatchState.derive(installed: true, running: true, status: starting, pausedUntil: nil, now: now) == .starting)
    }

    @Test func readsLaunchctlPrint() {
        let out = """
            system/dev.macximesed.watch = {
            \tactive count = 1
            \tstate = running
            \tprogram = /Users/v/Applications/Macximesed.app/Contents/MacOS/macx
            \tpid = 37452
            \t\tstate = active
            }
            """
        let info = LaunchdInfo.parse(out)
        #expect(info.state == "running")
        #expect(info.pid == 37452)
        #expect(LaunchdInfo.parse("Bad request.").pid == nil)
    }
}

@Suite("Mac app: pause")
struct WatchPauseTests {
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("macx-pause-\(UUID().uuidString).json") }

    @Test func parsesDurations() {
        #expect(WatchPause.parseDuration("1h") == 3600)
        #expect(WatchPause.parseDuration("30m") == 1800)
        #expect(WatchPause.parseDuration("90") == 5400)  // plain number = minutes
        #expect(WatchPause.parseDuration("0") == nil)
        #expect(WatchPause.parseDuration("25h") == nil)  // at most a day: a forgotten pause must still end
        #expect(WatchPause.parseDuration("soon") == nil)
    }

    @Test func pauseIsHonouredOnlyFromATrustedOwnerAndUntilItEnds() throws {
        let file = temp()
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_000)
        try WatchPause.write(until: Date(timeIntervalSince1970: 4_600), to: file)
        let me = getuid()
        #expect(WatchPause.activeUntil(file: file, now: now, trustedOwner: me) == Date(timeIntervalSince1970: 4_600))
        // Written by anyone but root (here: owned by us, trusted owner root) → ignored, so malware can't pause it.
        if me != 0 { #expect(WatchPause.activeUntil(file: file, now: now, trustedOwner: 0) == nil) }
        // Ended.
        #expect(WatchPause.activeUntil(file: file, now: Date(timeIntervalSince1970: 4_601), trustedOwner: me) == nil)
        // Writable by group or others → ignored.
        chmod(file.path, 0o666)
        #expect(WatchPause.activeUntil(file: file, now: now, trustedOwner: me) == nil)
        chmod(file.path, 0o644)
        WatchPause.clear(file)
        #expect(WatchPause.activeUntil(file: file, now: now, trustedOwner: me) == nil)
    }

    @Test func pauseFurtherThanADayAheadIsIgnored() throws {
        let file = temp()
        defer { try? FileManager.default.removeItem(at: file) }
        try WatchPause.write(until: Date(timeIntervalSince1970: 1_000 + 2 * 86_400), to: file)
        #expect(WatchPause.activeUntil(file: file, now: Date(timeIntervalSince1970: 1_000), trustedOwner: getuid()) == nil)
    }
}

@Suite("Mac app: admin prompt")
struct AdminCommandTests {
    @Test func quotesForTheShellAndForAppleScript() {
        let s = AdminCommand.appleScript(
            executable: "/Users/v/Applications/Macximesed.app/Contents/MacOS/macx", arguments: ["daemon", "pause", "--for", "1h"])
        #expect(
            s
                == #"do shell script "'/Users/v/Applications/Macximesed.app/Contents/MacOS/macx' 'daemon' 'pause' '--for' '1h'" with administrator privileges"#
        )
        let tricky = AdminCommand.appleScript(executable: "/tmp/a b/it's \"x\"", arguments: [])
        #expect(tricky == #"do shell script "'/tmp/a b/it'\\''s \"x\"'" with administrator privileges"#)
    }
}

@Suite("Mac app: pause gate in the watch loop")
struct PauseGateTests {
    final class Box: @unchecked Sendable {
        var until: Date?
        var reads = 0
    }

    @Test func readsThePauseFileAtMostEveryTwoSecondsAndFollowsIt() {
        let box = Box()
        var gate = PauseGate(interval: 2) { _ in
            box.reads += 1
            return box.until
        }
        let t0 = Date(timeIntervalSince1970: 100)
        #expect(gate.isPaused(now: t0) == false)
        box.until = Date(timeIntervalSince1970: 200)
        #expect(gate.isPaused(now: t0.addingTimeInterval(1)) == false)  // cached
        #expect(box.reads == 1)
        #expect(gate.isPaused(now: t0.addingTimeInterval(2)) == true)
        #expect(box.reads == 2)
        // It ends on time even between reads.
        #expect(gate.isPaused(now: Date(timeIntervalSince1970: 200.5)) == false)
    }

    @Test func pausedWatchStillLogsButStopsNotifyingAndFreezing() {
        #expect(PauseGate.effects(paused: true) == .init(log: true, notify: false, freeze: false))
        #expect(PauseGate.effects(paused: false) == .init(log: true, notify: true, freeze: true))
    }
}

@Suite("Mac app: updates keep the app openable")
struct UpdatedInfoTests {
    @Test func updateAddsTheAppSwitchToAnOlderBundleAndKeepsEverythingElse() {
        let old: [String: Any] = ["CFBundleIdentifier": "dev.macximesed.macx", "CFBundleShortVersionString": "0.2.0", "LSUIElement": true]
        let new = UpdateInstaller.updatedInfo(old, version: "0.3.0")
        #expect(new["CFBundleShortVersionString"] as? String == "0.3.0")
        #expect(new["CFBundleVersion"] as? String == "0.3.0")
        #expect(new["CFBundleIdentifier"] as? String == "dev.macximesed.macx")
        #expect(new["LSUIElement"] as? Bool == true)
        #expect((new["LSEnvironment"] as? [String: String])?["MACX_APP"] == "1")
    }

    @Test func otherLaunchEnvironmentValuesStay() {
        let old: [String: Any] = ["LSEnvironment": ["OTHER": "x"]]
        let env = UpdateInstaller.updatedInfo(old, version: "1.0.0")["LSEnvironment"] as? [String: String]
        #expect(env == ["OTHER": "x", "MACX_APP": "1"])
    }
}
