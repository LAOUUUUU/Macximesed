import ArgumentParser
import MacxCore

@main
enum Entry {
    static func main() {
        Responsibility.becomeOwnResponsibleProcessIfNeeded()
        UpdateCheck.runIfDue(arguments: Array(CommandLine.arguments.dropFirst()))
        Macx.main()
    }
}

struct Macx: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macx",
        abstract: "Macximesed: speed up macOS and watch for stealer-style malware.",
        version: macxVersion,
        subcommands: [
            Scan.self, Clean.self, Apps.self, Check.self, Persist.self, Guard.self, Watch.self, Daemon.self, Alerts.self, Net.self,
            ESPassthrough.self,
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
