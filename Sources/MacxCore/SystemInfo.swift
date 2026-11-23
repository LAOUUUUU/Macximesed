import Foundation

/// One process from `ps -Ao pid=,pcpu=,rss=,comm=`.
public struct ProcessSample: Sendable, Equatable {
    public var pid: Int32
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var path: String

    public init(pid: Int32, cpuPercent: Double, memoryBytes: UInt64, path: String) {
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.path = path
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// Parses `ps` lines: pid, %cpu, rss in KB, then the command path (which may contain spaces).
    public static func parse(psOutput: String) -> [ProcessSample] {
        psOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                let pid = Int32(parts[0]),
                let cpu = Double(parts[1]),
                let rssKB = UInt64(parts[2])
            else { return nil }
            return ProcessSample(pid: pid, cpuPercent: cpu, memoryBytes: rssKB * 1024, path: String(parts[3]))
        }
    }

    public static func top(_ processes: [ProcessSample], limit: Int) -> [ProcessSample] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    public static func sample(using runner: CommandRunner) -> [ProcessSample] {
        guard let out = try? runner.run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="]) else { return [] }
        return parse(psOutput: out)
    }
}

public enum ThermalLevel: String, Sendable, Equatable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    /// At serious and above, macOS lowers CPU/GPU clocks to cool down.
    public var isThrottling: Bool { self == .serious || self == .critical }

    public static var current: ThermalLevel { ThermalLevel(ProcessInfo.processInfo.thermalState) }
}

public struct DiskUsage: Sendable, Equatable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(totalBytes - min(availableBytes, totalBytes)) / Double(totalBytes)
    }

    /// The startup volume, counting purgeable space as available the way Finder does.
    public static func startupVolume() -> DiskUsage? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskUsage(totalBytes: UInt64(total), availableBytes: UInt64(max(available, 0)))
    }
}

public func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
}
