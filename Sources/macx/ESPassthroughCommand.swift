import ArgumentParser
import Darwin
import Foundation
import MacxCore

/// Runs eslogger as macx's child, so eslogger's Full Disk Access check falls on Macximesed.app (macx is its
/// own responsible process) and not on whatever terminal started it. Used by scripts/eval/runtime.sh to
/// benchmark eslogger alone. Output goes straight to stdout; stop signals are passed on.
struct ESPassthrough: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eslogger", abstract: "Run eslogger under macx's Full Disk Access (for the evaluation).", shouldDisplay: false)

    @Argument(help: "eslogger event names, such as exec or open.") var events: [String]

    nonisolated(unsafe) static var keep: [DispatchSourceSignal] = []
    static let signalQueue = DispatchQueue(label: "macx.eslogger.signals")

    func validate() throws {
        guard !events.isEmpty, events.allSatisfy({ $0.range(of: "^[a-z_]+$", options: .regularExpression) != nil }) else {
            throw ValidationError("Give eslogger event names only (letters and underscores).")
        }
    }

    func run() throws {
        guard geteuid() == 0 else { throw UserError("eslogger needs root: sudo macx eslogger \(events.joined(separator: " "))") }
        let es = Process()
        es.executableURL = URL(fileURLWithPath: "/usr/bin/eslogger")
        es.arguments = events
        es.standardOutput = FileHandle.standardOutput
        es.standardError = FileHandle.standardError
        try es.run()
        let child = es.processIdentifier
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: Self.signalQueue)
            src.setEventHandler { kill(child, sig) }
            src.resume()
            Self.keep.append(src)
        }
        es.waitUntilExit()
        throw ExitCode(es.terminationStatus)
    }
}
