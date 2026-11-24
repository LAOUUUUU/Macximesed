import Foundation
import Testing

@testable import MacxCore

@Suite("Medium tier (macx tune)")
struct TuneTests {
    @Test func catalogHasTheReversibleSettings() {
        let ids = Set(Tune.catalog.map(\.id))
        #expect(
            ids.isSuperset(of: [
                "reduce-transparency", "reduce-motion", "no-window-animations", "fast-window-resize", "dock-no-launch-bounce",
            ]))
        #expect(Tune.catalog.allSatisfy { !$0.title.isEmpty && !$0.why.isEmpty })
    }

    @Test func applyAndUndoOneTweakLeavesTheOthers() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("tune")
        let sys = FakeSystem()
        try Tune.apply(["reduce-motion", "no-window-animations"], folder: file, uid: 501, system: sys)
        #expect(sys.defaults["com.apple.universalaccess|reduceMotion"] == .bool(true))
        #expect(sys.defaults["NSGlobalDomain|NSAutomaticWindowAnimationsEnabled"] == .bool(false))
        let report = try Tune.undo(["reduce-motion"], folder: file, system: sys)
        #expect(report.failed.isEmpty)
        #expect(sys.defaults["com.apple.universalaccess|reduceMotion"] == nil)
        #expect(sys.defaults["NSGlobalDomain|NSAutomaticWindowAnimationsEnabled"] == .bool(false))
        #expect(Tune.applied(folder: file) == ["no-window-animations"])
        _ = try Tune.undo(nil, folder: file, system: sys)
        #expect(Tune.applied(folder: file).isEmpty)
        #expect(sys.defaults["NSGlobalDomain|NSAutomaticWindowAnimationsEnabled"] == nil)
    }

    @Test func applyingTwiceAddsNothing() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("tune")
        let sys = FakeSystem()
        try Tune.apply(["reduce-motion"], folder: file, uid: 501, system: sys)
        try Tune.apply(["reduce-motion"], folder: file, uid: 501, system: sys)
        #expect(TweakLedger.load(at: file.appendingPathComponent("reduce-motion.json"))?.changes.count == 1)
    }

    @Test func turningOffAThirdPartyAgentUsesLaunchctlAndCanBeUndone() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("tune")
        let sys = FakeSystem()
        try Tune.apply(["agent:com.spotify.webhelper"], folder: file, uid: 501, system: sys)
        #expect(sys.commands.contains(["/bin/launchctl", "disable", "gui/501/com.spotify.webhelper"]))
        _ = try Tune.undo(["agent:com.spotify.webhelper"], folder: file, system: sys)
        #expect(sys.commands.contains(["/bin/launchctl", "enable", "gui/501/com.spotify.webhelper"]))
    }

    @Test func refusesAppleAgentsAndUnknownTweaks() {
        let sys = FakeSystem()
        let file = URL(fileURLWithPath: "/tmp/never-written-\(UUID().uuidString)")
        #expect(throws: Tune.Problem.self) { try Tune.apply(["agent:com.apple.photoanalysisd"], folder: file, uid: 501, system: sys) }
        #expect(throws: Tune.Problem.self) { try Tune.apply(["agent:bad label;rm"], folder: file, uid: 501, system: sys) }
        #expect(throws: Tune.Problem.self) { try Tune.apply(["make-it-fast"], folder: file, uid: 501, system: sys) }
    }

    @Test func globalDomainMapsToAnyApplication() {
        #expect(RealSystem.cfDomain("NSGlobalDomain") == kCFPreferencesAnyApplication)
        #expect(RealSystem.cfDomain("com.apple.dock") as String == "com.apple.dock")
    }
}
