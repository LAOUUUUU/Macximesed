import Foundation
import Testing

@testable import MacxCore

@Suite("Risky tier")
struct RiskyTests {
    final class Fake: CommandRunner, @unchecked Sendable {
        var calls: [String] = []
        var outputs: [String: String] = [:]
        func run(_ executable: String, _ arguments: [String]) throws -> String {
            let line = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
            calls.append(line)
            return outputs[line] ?? ""
        }
    }

    let custom = """
        Battery Power:
         hibernatemode        3
         powernap             1
         standby              1
        AC Power:
         hibernatemode        25
         powernap             0
        """

    @Test func pmsetValuesPerPowerSource() {
        #expect(Risky.pmsetValues(custom, key: "hibernatemode") == ["b": "3", "c": "25"])
        #expect(Risky.pmsetValues(custom, key: "powernap") == ["b": "1", "c": "0"])
        #expect(Risky.pmsetValues(custom, key: "nope").isEmpty)
    }

    @Test func spotlightStateAndTimeMachineSnapshotsOnly() {
        #expect(Risky.spotlightOn("/:\n\tIndexing enabled. \n"))
        #expect(!Risky.spotlightOn("/:\n\tIndexing disabled.\n"))
        let list = """
            Snapshots for volume group containing disk /:
            com.apple.os.update-7F504400EE1B
            com.apple.TimeMachine.2026-11-24-101500.local
            com.apple.TimeMachine.2026-11-25-091000.local
            """
        // macOS update snapshots (rollback) are never touched.
        #expect(Risky.timeMachineSnapshots(list) == ["2026-11-24-101500", "2026-11-25-091000"])
    }

    @Test func hibernationStoresTheOldValuesAndUndoPutsThemBack() throws {
        let r = Fake()
        r.outputs["pmset -g custom"] = custom
        var ledger = RiskyLedger()
        try Risky.apply(.hibernation, ledger: &ledger, runner: r, removeFile: { _ in })
        #expect(ledger.before["hibernation"] == ["b": "3", "c": "25"])
        #expect(r.calls.contains("pmset -b hibernatemode 0") && r.calls.contains("pmset -c hibernatemode 0"))
        r.calls = []
        try Risky.undo(.hibernation, ledger: &ledger, runner: r)
        #expect(r.calls.contains("pmset -b hibernatemode 3") && r.calls.contains("pmset -c hibernatemode 25"))
        #expect(ledger.before["hibernation"] == nil)
    }

    @Test func applyingTwiceKeepsTheOriginalBeforeValue() throws {
        let r = Fake()
        r.outputs["pmset -g custom"] = custom
        var ledger = RiskyLedger()
        try Risky.apply(.powerNap, ledger: &ledger, runner: r, removeFile: { _ in })
        r.outputs["pmset -g custom"] = "Battery Power:\n powernap 0\nAC Power:\n powernap 0\n"
        try Risky.apply(.powerNap, ledger: &ledger, runner: r, removeFile: { _ in })
        #expect(ledger.before["powernap"] == ["b": "1", "c": "0"])
    }

    @Test func spotlightOffAndOn() throws {
        let r = Fake()
        r.outputs["mdutil -s /"] = "/:\n\tIndexing enabled.\n"
        var ledger = RiskyLedger()
        try Risky.apply(.spotlight, ledger: &ledger, runner: r, removeFile: { _ in })
        #expect(r.calls.contains("mdutil -a -i off"))
        try Risky.undo(.spotlight, ledger: &ledger, runner: r)
        #expect(r.calls.contains("mdutil -a -i on"))
        // Already off before we came: undo leaves it off.
        r.outputs["mdutil -s /"] = "/:\n\tIndexing disabled.\n"
        r.calls = []
        try Risky.apply(.spotlight, ledger: &ledger, runner: r, removeFile: { _ in })
        try Risky.undo(.spotlight, ledger: &ledger, runner: r)
        #expect(!r.calls.contains("mdutil -a -i on"))
    }

    @Test func snapshotsAreDeletedOneByOneAndHaveNoUndo() throws {
        let r = Fake()
        r.outputs["tmutil listlocalsnapshots /"] = "com.apple.os.update-X\ncom.apple.TimeMachine.2026-11-24-101500.local\n"
        var ledger = RiskyLedger()
        try Risky.apply(.snapshots, ledger: &ledger, runner: r, removeFile: { _ in })
        #expect(r.calls.contains("tmutil deletelocalsnapshots 2026-11-24-101500"))
        #expect(!r.calls.contains { $0.contains("os.update") })
        #expect(Risky.info(.snapshots).undoable == false)
        #expect(throws: RiskyError.self) { try Risky.undo(.snapshots, ledger: &ledger, runner: r) }
    }

    @Test func undoScriptHasEveryStoredValueQuoted() {
        var ledger = RiskyLedger()
        ledger.before["hibernation"] = ["b": "3", "c": "25"]
        ledger.before["spotlight"] = ["/": "on"]
        let script = Risky.undoScript(ledger)
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("/usr/bin/pmset -b hibernatemode '3'"))
        #expect(script.contains("/usr/bin/pmset -c hibernatemode '25'"))
        #expect(script.contains("/usr/bin/mdutil -a -i on"))
    }

    @Test func theConfirmationWordIsTheItemName() {
        #expect(Risky.confirms(.hibernation, typed: " hibernation "))
        #expect(!Risky.confirms(.hibernation, typed: "yes"))
    }
}
