import ArgumentParser
import Foundation
import MacxCore

@main
enum Entry {
    static func main() {
        // -v / -vv / --verbose work on every command: they're taken out here, before ArgumentParser sees them.
        let logSettings = LogSettings.from(
            arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
        let args = logSettings.arguments
        if LaunchMode.decide(arguments: args, environment: ProcessInfo.processInfo.environment) == .app {
            // From a terminal (`macx app`) hand over to LaunchServices, so the app is its own process with its own
            // Full Disk Access, not a child of the terminal. A development build outside the app runs in place.
            if args == ["app"], let exe = Responsibility.executablePath,
                let bundle = UpdateInstaller.enclosingApp(of: URL(fileURLWithPath: exe).resolvingSymlinksInPath())
            {
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [bundle.path]
                try? open.run()
                open.waitUntilExit()
                return
            }
            startLog(.app, logSettings)
            Log.info("app", "Macximesed \(macxVersion) started")
            MainActor.assumeIsolated { MacxApp.run() }
        }
        Responsibility.becomeOwnResponsibleProcessIfNeeded()
        startLog(LogRole.of(arguments: args), logSettings)
        Log.debug("start", "macx \(macxVersion), command: \(LogRole.commandName(args)), uid \(geteuid())")
        UpdateCheck.runIfDue(arguments: args)
        // A game session whose game quit while macx wasn't watching (crash, closed terminal) leaves Boost on.
        if geteuid() != 0, GameSessionGuard.recoverIfNeeded() {
            FileHandle.standardError.write(Data("macx: the last game session ended without macx; Boost was turned off.\n".utf8))
        }
        Macx.main(args)
    }

    /// Home folders are written as `~`: our own, and under sudo or in the daemon, the user macx works for.
    static func startLog(_ role: LogRole, _ settings: LogSettings) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homes = [WatchUser.resolve()?.home.path, home.path].compactMap { $0 }
        Log.start(role: role, settings: settings, home: home, homes: homes)
    }
}

struct Macx: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macx",
        abstract: "Macximesed: speed up macOS and watch for stealer-style malware.",
        discussion: """
            Add -v (or -vv for even more) to any command to see what it's doing. The details also go to \
            ~/Library/Logs/Macximesed/cli.log. MACX_LOG=debug does the same without printing them.
            """,
        version: macxVersion,
        subcommands: [
            Scan.self, Clean.self, Apps.self, Check.self, Persist.self, Guard.self, Watch.self, Daemon.self, Alerts.self, Net.self,
            Chamber.self, Top.self, BoostCommand.self, TuneCommand.self, GamesCommand.self, ESPassthrough.self,
            Incident.self, Privacy.self,
            Update.self,
            Undo.self,
        ]
    )
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read-only report: protections, heat, disk and the busiest processes. Changes nothing."
    )

    @Option(name: .shortAndLong, help: "How many processes to list.")
    var top: Int = 10

    func run() throws {
        print(ScanReport.collect(topLimit: max(top, 0)).render())
    }
}
