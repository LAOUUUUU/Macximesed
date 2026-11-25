import Darwin
import Foundation

/// Whether memory is what's slowing the Mac down: macOS's own pressure level and how much is swapped to disk.
/// On a 16 GB fanless Air, memory is often the bottleneck rather than the CPU.
public struct MemoryState: Sendable, Equatable {
    public enum Pressure: Sendable, Equatable {
        case normal, warning, critical

        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        public init(level: Int) {
            switch level {
            case 4: self = .critical
            case 2: self = .warning
            default: self = .normal
            }
        }

        public var label: String {
            switch self {
            case .normal: "Memory is fine"
            case .warning: "Memory is tight"
            case .critical: "Memory is very tight"
            }
        }
    }

    public var pressure: Pressure
    public var physicalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64

    public static func current() -> MemoryState? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 1
        var physical: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &physical, &size, nil, 0) == 0 else { return nil }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        let gotSwap = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        return MemoryState(
            pressure: Pressure(level: pressure), physicalBytes: physical, swapUsedBytes: gotSwap ? swap.xsu_used : 0,
            swapTotalBytes: gotSwap ? swap.xsu_total : 0)
    }
}
