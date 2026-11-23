import Foundation

/// Runs a system tool and returns its standard output. Injected so parsers can be tested with fixtures.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

public enum CommandError: Error, Equatable {
    case failed(String, Int32)
}

public struct CapturedOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

extension ProcessRunner {
    /// Like `run`, but keeps stderr and the exit status instead of throwing (for tools such as
    /// `spctl` that report on stderr and use exit codes as answers).
    public static func capture(_ executable: String, _ arguments: [String]) -> CapturedOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        // Read both pipes concurrently so a chatty tool can't fill one and block.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CapturedOutput(
            status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// Runs real processes in the C locale, so output is the same on every language setting.
/// Standard error is discarded; a non-zero exit throws.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandError.failed(executable, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
