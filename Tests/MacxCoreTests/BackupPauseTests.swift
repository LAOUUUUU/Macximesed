import Foundation
import Testing

@testable import MacxCore

@Suite("Pause backups while playing")
struct BackupPauseTests {
    final class Recorder: CommandRunner, @unchecked Sendable {
        var calls: [[String]] = []
        var outputs: [String: String] = [:]
        func run(_ executable: String, _ arguments: [String]) throws -> String {
            calls.append([executable] + arguments)
            return outputs[arguments.joined(separator: " ")] ?? ""
        }
    }

    @Test func onlyPausesBackupsThatWereOnAndPutsThemBack() {
        #expect(BackupPause.decide(enabled: true, gameAlive: true, weTookItDown: false, autoBackupOn: true) == .takeDown)
        // Backups already off: leave them alone, and never turn them on afterwards.
        #expect(BackupPause.decide(enabled: true, gameAlive: true, weTookItDown: false, autoBackupOn: false) == .nothing)
        #expect(BackupPause.decide(enabled: true, gameAlive: true, weTookItDown: true, autoBackupOn: false) == .nothing)
        #expect(BackupPause.decide(enabled: true, gameAlive: false, weTookItDown: true, autoBackupOn: false) == .bringUp)
        // Switched off mid-game: put back.
        #expect(BackupPause.decide(enabled: false, gameAlive: true, weTookItDown: true, autoBackupOn: false) == .bringUp)
        #expect(BackupPause.decide(enabled: false, gameAlive: true, weTookItDown: false, autoBackupOn: true) == .nothing)
    }

    @Test func pausingStopsTheRunningBackupAndChecksItTookEffect() {
        let r = Recorder()
        r.outputs["read /Library/Preferences/com.apple.TimeMachine AutoBackup"] = "0"
        #expect(BackupPause.apply(.takeDown, runner: r))
        #expect(r.calls.map { $0.dropFirst().joined(separator: " ") }.prefix(2) == ["stopbackup", "disable"])
        // Still on afterwards (e.g. no Full Disk Access): reported as not done.
        let stuck = Recorder()
        stuck.outputs["read /Library/Preferences/com.apple.TimeMachine AutoBackup"] = "1"
        #expect(!BackupPause.apply(.takeDown, runner: stuck))
        let up = Recorder()
        #expect(BackupPause.apply(.bringUp, runner: up))
        #expect(up.calls.first?.dropFirst().joined(separator: " ") == "enable")
    }

    @Test func configuredOnlyWithADestination() {
        #expect(!BackupPause.configured(destinationInfo: "tmutil: No destinations configured.\n"))
        #expect(BackupPause.configured(destinationInfo: "Name          : Backup\nKind          : Local\nID            : 1A2B\n"))
    }

    @Test func oldSettingsFilesStillLoad() throws {
        let old = #"{"gameNetwork":true,"rawMouse":false,"socdApps":[]}"#
        let h = try JSONDecoder().decode(GameHooks.self, from: Data(old.utf8))
        #expect(h.gameNetwork && h.pauseBackups != true)
    }
}
