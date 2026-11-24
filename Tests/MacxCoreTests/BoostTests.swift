import Foundation
import Testing

@testable import MacxCore

/// Records every system change instead of making it.
final class FakeSystem: SystemControl, @unchecked Sendable {
    var defaults: [String: PlistValue] = [:]
    var demoted: Set<Int32> = []
    var commands: [[String]] = []
    var alive: [Int32: UInt64] = [:]  // pid → start time
    var failRestoreOf: String?

    func key(_ d: String, _ k: String) -> String { "\(d)|\(k)" }
    func read(domain: String, key k: String) -> PlistValue? { defaults[key(domain, k)] }
    func write(domain: String, key k: String, value: PlistValue?) throws {
        if let failRestoreOf, failRestoreOf == k, value == nil || value == .bool(false) { throw CocoaError(.fileWriteNoPermission) }
        defaults[key(domain, k)] = value
    }
    func setBackground(pid: Int32, on: Bool) throws {
        if on { demoted.insert(pid) } else { demoted.remove(pid) }
    }
    func startTime(pid: Int32) -> UInt64? { alive[pid] }
    func spawn(_ args: [String]) throws -> Int32 {
        commands.append(args)
        let pid = Int32(9000 + commands.count)
        alive[pid] = 1
        return pid
    }
    func kill(pid: Int32) { alive[pid] = nil }
    func run(_ args: [String]) throws { commands.append(args) }
}

@Suite("Settings ledger")
struct LedgerTests {
    @Test func writesBeforeValueFirstAndRestoresIt() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        sys.defaults["com.apple.universalaccess|reduceMotion"] = .bool(false)
        var ledger = try TweakLedger.open(at: tmp.url.appendingPathComponent("boost.json"), purpose: "boost")
        try ledger.setDefault(domain: "com.apple.universalaccess", key: "reduceMotion", to: .bool(true), system: sys)
        #expect(sys.defaults["com.apple.universalaccess|reduceMotion"] == .bool(true))
        // The ledger on disk already has the "before" value: a crash now can still be undone.
        let reloaded = try #require(TweakLedger.load(at: tmp.url.appendingPathComponent("boost.json")))
        #expect(reloaded.changes.count == 1)
        let report = reloaded.restore(system: sys)
        #expect(sys.defaults["com.apple.universalaccess|reduceMotion"] == .bool(false))
        #expect(report.failed.isEmpty)
        #expect(TweakLedger.load(at: tmp.url.appendingPathComponent("boost.json")) == nil)
    }

    @Test func absentValueIsRemovedAgainNotSetToFalse() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        var ledger = try TweakLedger.open(at: tmp.url.appendingPathComponent("b.json"), purpose: "boost")
        try ledger.setDefault(domain: "com.example.game", key: "NSAppSleepDisabled", to: .bool(true), system: sys)
        _ = ledger.restore(system: sys)
        #expect(sys.defaults["com.example.game|NSAppSleepDisabled"] == nil)
    }

    @Test func settingAlreadyAtTheValueIsLeftAlone() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        sys.defaults["com.apple.universalaccess|reduceTransparency"] = .bool(true)
        var ledger = try TweakLedger.open(at: tmp.url.appendingPathComponent("b.json"), purpose: "boost")
        try ledger.setDefault(domain: "com.apple.universalaccess", key: "reduceTransparency", to: .bool(true), system: sys)
        #expect(ledger.changes.isEmpty)
    }

    @Test func backgroundQoSIsUndoneOnlyForTheSameProcess() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        sys.alive = [100: 5000, 101: 6000]
        var ledger = try TweakLedger.open(at: tmp.url.appendingPathComponent("b.json"), purpose: "boost")
        try ledger.demote(pid: 100, system: sys)
        try ledger.demote(pid: 101, system: sys)
        #expect(sys.demoted == [100, 101])
        // 101 exited and its pid was reused by another process.
        sys.alive[101] = 9999
        _ = ledger.restore(system: sys)
        #expect(sys.demoted == [101])
    }

    @Test func oneFailedRestoreDoesNotStopTheRest() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        sys.alive = [100: 1]
        sys.failRestoreOf = "reduceMotion"
        var ledger = try TweakLedger.open(at: tmp.url.appendingPathComponent("b.json"), purpose: "boost")
        try ledger.setDefault(domain: "com.apple.universalaccess", key: "reduceMotion", to: .bool(true), system: sys)
        try ledger.demote(pid: 100, system: sys)
        let report = ledger.restore(system: sys)
        #expect(sys.demoted.isEmpty)
        #expect(report.failed.count == 1)
        // A ledger with a failed item is kept, so it can be retried.
        #expect(TweakLedger.load(at: tmp.url.appendingPathComponent("b.json")) != nil)
    }

    @Test func caffeinateIsStoppedOnRestore() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        var ledger = try TweakLedger.open(at: tmp.url.appendingPathComponent("b.json"), purpose: "boost")
        let pid = try ledger.keepAwake(system: sys)
        #expect(sys.alive[pid] != nil)
        _ = ledger.restore(system: sys)
        #expect(sys.alive[pid] == nil)
    }
}

@Suite("Boost plan")
struct BoostPlanTests {
    func use(_ pid: Int32, _ path: String, cpu: Double, uid: uid_t = 501) -> CPUUse {
        CPUUse(pid: pid, uid: uid, path: path, cpuPercent: cpu)
    }

    @Test func demotesOwnHogsButNeverTheFocusAppAppleOrOtherUsers() {
        let samples = [
            use(10, "/Applications/Game.app/Contents/MacOS/Game", cpu: 180),
            use(11, "/Applications/Game.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", cpu: 40),
            use(
                20, "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)",
                cpu: 35),
            use(21, "/Applications/Docker.app/Contents/MacOS/com.docker.backend", cpu: 22),
            use(30, "/System/Library/CoreServices/WindowServer", cpu: 60),
            use(31, "/usr/libexec/mds_stores", cpu: 30),
            use(40, "/Applications/Other.app/Contents/MacOS/Other", cpu: 50, uid: 502),
            use(50, "/Applications/Quiet.app/Contents/MacOS/Quiet", cpu: 1),
        ]
        let plan = Boost.plan(
            focus: URL(fileURLWithPath: "/Applications/Game.app"), samples: samples, uid: 501, selfPID: 999, limit: 5)
        #expect(plan.demote.map(\.pid) == [20, 21])
    }

    @Test func boostSettingsIncludeAppNapForTheFocusApp() {
        let plan = Boost.plan(
            focus: URL(fileURLWithPath: "/Applications/Game.app"), focusBundleID: "com.example.game", samples: [], uid: 501, selfPID: 1)
        #expect(plan.settings.contains { $0.domain == "com.example.game" && $0.key == "NSAppSleepDisabled" && $0.value == .bool(true) })
        #expect(plan.settings.contains { $0.domain == "com.apple.universalaccess" && $0.key == "reduceTransparency" })
        #expect(plan.settings.contains { $0.domain == "com.apple.universalaccess" && $0.key == "reduceMotion" })
    }

    @Test func applyThenRestorePutsEverythingBack() throws {
        let tmp = try TempDir()
        let sys = FakeSystem()
        sys.alive = [20: 1, 21: 2]
        sys.defaults["com.apple.universalaccess|reduceMotion"] = .bool(false)
        let plan = Boost.plan(
            focus: URL(fileURLWithPath: "/Applications/Game.app"), focusBundleID: "com.example.game",
            samples: [use(20, "/Applications/Slack.app/Contents/MacOS/Slack", cpu: 30), use(21, "/opt/x/bin/indexer", cpu: 25)],
            uid: 501, selfPID: 1)
        let file = tmp.url.appendingPathComponent("boost.json")
        let applied = try Boost.apply(plan, ledgerAt: file, system: sys)
        #expect(sys.demoted == [20, 21])
        #expect(sys.defaults["com.example.game|NSAppSleepDisabled"] == .bool(true))
        #expect(applied.changes.count >= 5)
        _ = try #require(TweakLedger.load(at: file)).restore(system: sys)
        #expect(sys.demoted.isEmpty)
        #expect(sys.defaults["com.apple.universalaccess|reduceMotion"] == .bool(false))
        #expect(sys.defaults["com.example.game|NSAppSleepDisabled"] == nil)
        #expect(sys.alive.keys.allSatisfy { $0 < 9000 })  // caffeinate stopped
    }

    @Test func boostOnTwiceDoesNotStackLedgers() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("boost.json")
        let sys = FakeSystem()
        let plan = Boost.plan(focus: nil, samples: [], uid: 501, selfPID: 1)
        _ = try Boost.apply(plan, ledgerAt: file, system: sys)
        #expect(throws: Boost.Problem.alreadyOn) { try Boost.apply(plan, ledgerAt: file, system: sys) }
    }
}
