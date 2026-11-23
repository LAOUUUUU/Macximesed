import Foundation

/// Everything `macx scan` reports. Read-only: building one changes nothing on the Mac.
public struct ScanReport: Sendable, Equatable {
    public var protections: Protections
    public var topProcesses: [ProcessSample]
    public var disk: DiskUsage?
    public var thermal: ThermalLevel

    public init(protections: Protections, topProcesses: [ProcessSample], disk: DiskUsage?, thermal: ThermalLevel) {
        self.protections = protections
        self.topProcesses = topProcesses
        self.disk = disk
        self.thermal = thermal
    }

    public static func collect(using runner: CommandRunner = ProcessRunner(), topLimit: Int = 10) -> ScanReport {
        ScanReport(
            protections: .check(using: runner),
            topProcesses: ProcessSample.top(ProcessSample.sample(using: runner), limit: topLimit),
            disk: .startupVolume(),
            thermal: .current
        )
    }

    /// Plain-language problems worth acting on.
    public var warnings: [String] {
        var out: [String] = []
        let named: [(String, ProtectionState)] = [
            ("SIP", protections.sip), ("Gatekeeper", protections.gatekeeper),
            ("FileVault", protections.fileVault), ("Firewall", protections.firewall),
        ]
        for (name, state) in named where state == .off || state == .partial {
            out.append("\(name) is \(state == .off ? "off" : "only partly on"). Turn it back on.")
        }
        if let disk, disk.usedFraction >= 0.9 {
            out.append("Disk is \(Int((disk.usedFraction * 100).rounded()))% full. macOS slows down when it runs out of room.")
        }
        if thermal.isThrottling {
            out.append("The Mac is hot and throttling (CPU/GPU clocks lowered).")
        }
        return out
    }

    public func render() -> String {
        var lines: [String] = ["Macximesed scan", ""]
        lines.append("Protections")
        let named: [(String, ProtectionState)] = [
            ("SIP", protections.sip), ("Gatekeeper", protections.gatekeeper),
            ("FileVault", protections.fileVault), ("Firewall", protections.firewall),
        ]
        for (name, state) in named {
            lines.append("  \(name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(label(state))")
        }
        lines.append("")
        lines.append("Heat")
        lines.append("  \(thermal.rawValue)\(thermal.isThrottling ? " (throttling)" : "")")
        lines.append("")
        lines.append("Disk")
        if let disk {
            let pct = Int((disk.usedFraction * 100).rounded())
            lines.append("  \(formatBytes(disk.availableBytes)) free of \(formatBytes(disk.totalBytes)) (\(pct)% used)")
        } else {
            lines.append("  unknown")
        }
        lines.append("")
        lines.append("Top processes by CPU")
        for p in topProcesses {
            let cpu = String(format: "%5.1f%%", p.cpuPercent)
            lines.append(
                "  \(cpu)  \(formatBytes(p.memoryBytes).padding(toLength: 9, withPad: " ", startingAt: 0))  \(p.name)  (pid \(p.pid))")
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            lines.append(contentsOf: warnings.map { "  ! \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private func label(_ state: ProtectionState) -> String {
        switch state {
        case .on: "on"
        case .off: "OFF"
        case .partial: "PARTIAL"
        case .unknown: "unknown"
        }
    }
}
