import Foundation

/// Runs a system tool and returns its standard output. Injected so parsers can be tested with fixtures.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> String
}

public enum CommandError: Error, Equatable {
    case failed(String, Int32)
}

/// Runs real processes. Standard error is discarded; a non-zero exit throws.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
