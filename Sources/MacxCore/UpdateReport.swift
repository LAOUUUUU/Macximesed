import Foundation

/// The hash feed line `macx update` prints.
public enum HashFeedLine {
    public static func text(count: Int) -> String {
        "Malware hash feed: \(count) known sample\(count == 1 ? "" : "s") (checked offline)."
    }
}

/// What the Mac app shows after running `macx update` (or `--check`): the version news comes first, the hash feed
/// line goes behind the ⓘ. The app runs the CLI so updating has one code path.
public struct UpdateReport: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case upToDate
        case available(String)
        case urgent(String, reason: String)
        case installed(String)
        case failed(String)
    }

    public var status: Status
    public var feed: String?
    public var warnings: [String]

    public static func parse(_ output: String, exitCode: Int32) -> UpdateReport {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let feed = lines.first { $0.hasPrefix("Malware hash feed:") }
        let warnings = lines.filter { $0.contains("rollback attempt") || $0.hasPrefix("Warning:") }
        if exitCode != 0 {
            let last = lines.last.map { $0.hasPrefix("Error: ") ? String($0.dropFirst(7)) : $0 } ?? "Couldn't check."
            return UpdateReport(status: .failed(last), feed: feed, warnings: warnings)
        }
        if let line = lines.first(where: { $0.hasPrefix("Updated to ") }) {
            let v = line.dropFirst("Updated to ".count).prefix { $0 != " " }.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return UpdateReport(status: .installed(v), feed: feed, warnings: warnings)
        }
        if let line = lines.first(where: { $0.hasPrefix("macx ") && $0.contains(" is available") }) {
            let v = String(line.dropFirst(5).prefix { $0 != " " })
            let problem = "Your version has a security problem: "
            if let reason = lines.first(where: { $0.hasPrefix(problem) }) {
                return UpdateReport(status: .urgent(v, reason: String(reason.dropFirst(problem.count))), feed: feed, warnings: warnings)
            }
            return UpdateReport(status: .available(v), feed: feed, warnings: warnings)
        }
        if lines.contains(where: { $0.hasSuffix(" is up to date.") }) {
            return UpdateReport(status: .upToDate, feed: feed, warnings: warnings)
        }
        return UpdateReport(status: .failed(lines.last ?? "Couldn't check."), feed: feed, warnings: warnings)
    }
}
