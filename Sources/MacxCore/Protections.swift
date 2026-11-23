import Foundation

public enum ProtectionState: String, Sendable, Equatable {
    case on, off, partial, unknown
}

/// The macOS protections Macximesed never turns off (outside the Extreme level) and always reports.
public struct Protections: Sendable, Equatable {
    public var sip: ProtectionState
    public var gatekeeper: ProtectionState
    public var fileVault: ProtectionState
    public var firewall: ProtectionState

    public init(sip: ProtectionState, gatekeeper: ProtectionState, fileVault: ProtectionState, firewall: ProtectionState) {
        self.sip = sip
        self.gatekeeper = gatekeeper
        self.fileVault = fileVault
        self.firewall = firewall
    }

    /// Asks the system tools. None of these need root.
    public static func check(using runner: CommandRunner) -> Protections {
        func ask(_ tool: String, _ args: [String], _ parse: (String) -> ProtectionState) -> ProtectionState {
            guard let out = try? runner.run(tool, args) else { return .unknown }
            return parse(out)
        }
        return Protections(
            sip: ask("/usr/bin/csrutil", ["status"], parseSIP),
            gatekeeper: ask("/usr/sbin/spctl", ["--status"], parseGatekeeper),
            fileVault: ask("/usr/bin/fdesetup", ["status"], parseFileVault),
            firewall: ask("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], parseFirewall)
        )
    }

    static func parseSIP(_ out: String) -> ProtectionState {
        guard let line = out.split(separator: "\n").first(where: { $0.contains("System Integrity Protection status:") }) else {
            return .unknown
        }
        if line.contains("Custom Configuration") { return .partial }
        if line.contains("enabled") { return .on }
        if line.contains("disabled") { return .off }
        return .unknown
    }

    static func parseGatekeeper(_ out: String) -> ProtectionState {
        if out.contains("assessments enabled") { return .on }
        if out.contains("assessments disabled") { return .off }
        return .unknown
    }

    static func parseFileVault(_ out: String) -> ProtectionState {
        if out.contains("FileVault is On") { return .on }
        if out.contains("FileVault is Off") { return .off }
        if out.contains("Encryption in progress") || out.contains("Decryption in progress") { return .partial }
        return .unknown
    }

    static func parseFirewall(_ out: String) -> ProtectionState {
        if out.contains("Firewall is enabled") { return .on }
        if out.contains("Firewall is disabled") { return .off }
        return .unknown
    }
}
