import ArgumentParser
import Darwin
import Foundation
import MacxCore

struct Net: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show where a process (and anything it starts) connects to, as it happens.",
        discussion: """
            Reads the process's sockets from the kernel every --interval milliseconds and prints each new remote
            address once. Connections that open and close between two looks can be missed (see
            research/evaluation/network-results.md). Your own processes work without sudo; others need sudo.
            `macx watch` does the same automatically for every process behind a high or critical alert.
            """
    )

    @Argument(help: "Process ID.") var pid: Int32
    @Option(help: "Milliseconds between looks.") var interval: Int = 20
    @Option(help: "Stop after this many seconds (0 = until the process exits).") var seconds: Double = 0
    @Flag(help: "Include connections to this Mac (127.0.0.1, ::1).") var loopback = false
    @Flag(help: "Print every new connection, not just each new remote address.") var every = false

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard interval > 0 else { throw UserError("--interval must be above 0.") }
        guard NetConnections.of(pid: pid) != nil else {
            throw UserError(
                geteuid() == 0 ? "No process \(pid)." : "Can't read process \(pid): it's gone, or it isn't yours (try sudo).")
        }
        var tracker = NetTracker(followFor: seconds > 0 ? seconds : .infinity, includeLoopback: loopback, perConnection: every)
        tracker.watch(pid: Int(pid), reason: "macx net", path: ProcessTree.path(of: pid))
        let start = Date()
        while !tracker.watched.isEmpty {
            for e in tracker.poll() { Self.printEvent(e) }
            if seconds > 0, Date().timeIntervalSince(start) >= seconds { break }
            usleep(useconds_t(interval * 1000))
        }
    }

    static func printEvent(_ e: NetEvent) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let c = e.connection
        let name = (e.path as NSString).lastPathComponent
        print(
            "[\(time)] \(c.proto.rawValue) \(c.endpoint)\(c.state.map { " \($0)" } ?? "")  from \(name) (pid \(e.pid), local port \(c.localPort))"
        )
    }
}
