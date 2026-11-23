import ArgumentParser
import MacxCore

@main
struct Macx: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macx",
        abstract: "Macximesed: speed up macOS and watch for stealer-style malware.",
        version: "0.1.0",
        subcommands: [Scan.self, Clean.self, Apps.self, Persist.self, Undo.self]
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
