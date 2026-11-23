import Foundation

/// Runs a system tool and returns its standard output. Injected so parsers can be tested with fixtures.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

public enum CommandError: Error, Equatable {
    case failed(String, Int32)
    /// The tool didn't finish in time and was stopped. Callers treat it like the tool being unavailable.
    case timedOut(String)
}

public struct CapturedOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// Runs real processes in the C locale, so output is the same on every language setting. Every run has
/// a time limit and an empty stdin, so a tool that waits for input or an authorization prompt (as
/// `sfltool` can on a headless Mac) can never hang macx.
public struct ProcessRunner: CommandRunner {
    public static let defaultTimeout: TimeInterval = 30
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = ProcessRunner.defaultTimeout) { self.timeout = timeout }

    /// Standard error is discarded; a non-zero exit throws.
    public func run(_ executable: String, _ arguments: [String]) throws -> String {
        let r = try Self.execute(executable, arguments, timeout: timeout, keepStderr: false)
        guard r.status == 0 else { throw CommandError.failed(executable, r.status) }
        return r.stdout
    }

    /// Like `run`, but keeps stderr and the exit status instead of throwing (for tools such as `spctl`
    /// that report on stderr and use exit codes as answers). Nil when it can't start or runs out of time.
    public static func capture(_ executable: String, _ arguments: [String], timeout: TimeInterval = defaultTimeout) -> CapturedOutput? {
        try? execute(executable, arguments, timeout: timeout, keepStderr: true)
    }

    static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval, keepStderr: Bool) throws -> CapturedOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = keepStderr ? err : FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // Read the pipes on their own threads so a chatty tool can't fill one and block.
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if keepStderr {
            reading.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                reading.leave()
            }
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw CommandError.timedOut(executable)
        }
        // The tool has exited; give the readers a moment to drain (a leftover grandchild could keep a pipe open).
        _ = reading.wait(timeout: .now() + 2)
        return CapturedOutput(
            status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}
