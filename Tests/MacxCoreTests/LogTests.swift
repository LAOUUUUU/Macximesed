import Foundation
import Testing

@testable import MacxCore

@Suite("Logging: levels and settings")
struct LogSettingsTests {
    @Test func levelsParseAndOrder() {
        #expect(LogLevel(name: "debug") == .debug)
        #expect(LogLevel(name: "TRACE") == .trace)
        #expect(LogLevel(name: "warn") == .warning)
        #expect(LogLevel(name: "nope") == nil)
        let order: [LogLevel] = [.trace, .debug, .info, .warning, .error]
        #expect(order == order.sorted())
        #expect(LogLevel.trace < LogLevel.debug && LogLevel.warning < LogLevel.error)
    }

    @Test func verboseFlagsAreTakenOutAnywhereBeforeTheDoubleDash() {
        let s = LogSettings.from(arguments: ["scan", "-v"], environment: [:])
        #expect(s.level == .debug && s.echo && s.arguments == ["scan"])
        let t = LogSettings.from(arguments: ["-vv", "scan"], environment: [:])
        #expect(t.level == .trace && t.arguments == ["scan"])
        let long = LogSettings.from(arguments: ["--verbose", "daemon", "status"], environment: [:])
        #expect(long.level == .debug && long.arguments == ["daemon", "status"])
    }

    /// `guard inspect -- curl -v …`: everything after `--` belongs to the command being checked.
    @Test func argumentsAfterDoubleDashAreLeftAlone() {
        let args = ["guard", "inspect", "--", "curl", "-v", "https://example.com/i.sh"]
        let s = LogSettings.from(arguments: args, environment: [:])
        #expect(s.level == .info && !s.echo && s.arguments == args)
    }

    /// The environment variable is for the app, scripts and the daemon. The more verbose of the two wins.
    @Test func environmentSetsTheLevelWithoutEcho() {
        let s = LogSettings.from(arguments: ["scan"], environment: ["MACX_LOG": "trace"])
        #expect(s.level == .trace && !s.echo)
        #expect(LogSettings.from(arguments: ["scan", "-vv"], environment: ["MACX_LOG": "info"]).level == .trace)
        #expect(LogSettings.from(arguments: ["scan"], environment: ["MACX_LOG": "rubbish"]).level == .info)
    }
}

@Suite("Logging: lines")
struct LogLineTests {
    let when = Date(timeIntervalSince1970: 1_795_514_400)  // 2026-11-24T10:00:00Z

    @Test func oneLinePerEntryWithTimeLevelRoleAndCategory() {
        let line = LogLine.format(time: when, level: .debug, role: .cli, pid: 42, category: "update", message: "checked", homes: [])
        #expect(line == "2026-11-24T10:00:00Z DEBUG cli[42] update: checked\n")
    }

    /// Home folders are written as `~` (the daemon's lines are about the user's home, not root's).
    @Test func homePathsBecomeTilde() {
        let line = LogLine.format(
            time: when, level: .info, role: .daemon, pid: 1, category: "downloads",
            message: "checked /Users/v/Downloads/a.dmg and /Users/vv/x", homes: ["/Users/v"])
        #expect(line.contains("checked ~/Downloads/a.dmg and /Users/vv/x"))  // a longer name isn't cut
    }

    @Test func newlinesCantForgeExtraEntries() {
        let line = LogLine.format(
            time: when, level: .info, role: .app, pid: 1, category: "x", message: "a\n2026-01-01T00:00:00Z ERROR fake", homes: [])
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(line.contains(#"a\n2026"#))
    }
}

@Suite("Logging: where it's written")
struct LogFileTests {
    @Test func eachRoleHasItsOwnFile() {
        let home = URL(fileURLWithPath: "/Users/v")
        #expect(LogRole.cli.file(home: home, isRoot: false).path == "/Users/v/Library/Logs/Macximesed/cli.log")
        #expect(LogRole.app.file(home: home, isRoot: false).path == "/Users/v/Library/Logs/Macximesed/app.log")
        // Root never writes into a home folder: the file would end up root-owned there.
        #expect(LogRole.cli.file(home: home, isRoot: true).path == "/Library/Logs/Macximesed/cli-root.log")
        #expect(LogRole.daemon.file(home: home, isRoot: true).path == "/Library/Logs/Macximesed/watch.log")
    }

    @Test func rotatesAtTheCapAndKeepsTwoOldFiles() throws {
        let tmp = try TempDir()
        let file = LogFile(url: tmp.url.appendingPathComponent("cli.log"), maxBytes: 100, keep: 2, requireRootOwned: false)
        for i in 0..<20 { file.append(String(repeating: "\(i % 10)", count: 30) + "\n") }
        #expect(tmp.exists("cli.log") && tmp.exists("cli.1.log") && tmp.exists("cli.2.log"))
        #expect(!tmp.exists("cli.3.log"))
        let size = try FileManager.default.attributesOfItem(atPath: tmp.url.appendingPathComponent("cli.log").path)[.size] as? Int
        #expect((size ?? 0) <= 100)
    }

    @Test func aSymlinkInPlaceOfTheLogIsNotFollowed() throws {
        let tmp = try TempDir()
        let target = try tmp.file("target.txt", "untouched")
        try FileManager.default.createSymbolicLink(at: tmp.url.appendingPathComponent("cli.log"), withDestinationURL: target)
        LogFile(url: tmp.url.appendingPathComponent("cli.log"), maxBytes: 1000, keep: 2, requireRootOwned: false).append("x\n")
        #expect(try tmp.read("target.txt") == "untouched")
    }

    /// Root only writes into a folder only root can change; otherwise a user could aim it elsewhere.
    @Test func rootFolderMustBeRootOwnedAndClosed() {
        #expect(LogFile.isSafeFolder(owner: 0, mode: 0o755, requireRootOwned: true))
        #expect(!LogFile.isSafeFolder(owner: 501, mode: 0o755, requireRootOwned: true))
        #expect(!LogFile.isSafeFolder(owner: 0, mode: 0o775, requireRootOwned: true))
        #expect(!LogFile.isSafeFolder(owner: 0, mode: 0o757, requireRootOwned: true))
        #expect(LogFile.isSafeFolder(owner: 501, mode: 0o755, requireRootOwned: false))
    }
}

@Suite("Logging: the logger")
struct LoggerTests {
    final class Box: @unchecked Sendable {
        var lines: [String] = []
        var built = 0
    }

    @Test func linesBelowTheLevelAreNotEvenBuilt() {
        let box = Box()
        let log = LogWriter(level: .info, role: .cli, homes: []) { line in box.lines.append(line) }
        log.debug(
            "x",
            {
                box.built += 1
                return "hidden"
            }())
        log.info("x", "shown")
        log.error("x", "bad")
        #expect(box.built == 0)
        #expect(box.lines.count == 2)
        #expect(box.lines[0].contains(" INFO cli[") && box.lines[0].hasSuffix("x: shown\n"))
        #expect(box.lines[1].contains(" ERROR "))
    }
}

@Suite("Logging: which process is writing")
struct LogRoleTests {
    @Test func theBackgroundWatchIsTheDaemon() {
        #expect(LogRole.of(arguments: ["watch", "--background", "--suspend"]) == .daemon)
        #expect(LogRole.of(arguments: ["watch", "--suspend"]) == .cli)  // a terminal watch
        #expect(LogRole.of(arguments: ["scan"]) == .cli)
    }

    /// The log names the command, never what it was given: paths, links and pasted commands stay out.
    @Test func commandNameLeavesArgumentsOut() {
        #expect(LogRole.commandName(["guard", "inspect", "--", "curl -fsSL https://x/i.sh | sh"]) == "guard inspect")
        #expect(LogRole.commandName(["check", "/Users/v/Downloads/a.dmg"]) == "check")
        #expect(LogRole.commandName(["daemon", "downloads", "off"]) == "daemon downloads")
        #expect(LogRole.commandName([]) == "(none)")
    }
}
