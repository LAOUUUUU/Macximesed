import Darwin
import Foundation

/// CPU used by each process, from its CPU time between two snapshots (libproc `proc_pid_rusage`). Unlike
/// Activity Monitor's percentage this is real time on a core, not residency.
public enum CPUSampler {
    public struct Reading: Sendable, Equatable {
        public var cpuNanos: UInt64
        public var uid: uid_t
        public var path: String
    }

    public static func snapshot() -> [Int32: Reading] {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 32)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        var out: [Int32: Reading] = [:]
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            guard ok else { continue }
            var info = proc_bsdinfo()
            let uid = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 ? info.pbi_uid : 0
            // ri_*_time is in Mach absolute-time units on Apple silicon; convert to nanoseconds.
            let ticks = usage.ri_user_time + usage.ri_system_time
            let nanos = ticks * UInt64(tb.numer) / UInt64(max(tb.denom, 1))
            out[pid] = Reading(cpuNanos: nanos, uid: uid, path: ProcessTree.path(of: pid))
        }
        return out
    }

    /// Processes present in both snapshots, busiest first. 100% = one core fully used.
    public static func uses(before: [Int32: Reading], after: [Int32: Reading], interval: TimeInterval) -> [CPUUse] {
        guard interval > 0 else { return [] }
        return after.compactMap { pid, a -> CPUUse? in
            guard let b = before[pid], a.cpuNanos >= b.cpuNanos, a.path == b.path else { return nil }
            let pct = Double(a.cpuNanos - b.cpuNanos) / 1e9 / interval * 100
            return CPUUse(pid: pid, uid: a.uid, path: a.path, cpuPercent: pct)
        }
        .sorted { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.pid < $1.pid }
    }

    public static func sample(interval: TimeInterval = 1) -> [CPUUse] {
        let a = snapshot()
        Thread.sleep(forTimeInterval: interval)
        return uses(before: a, after: snapshot(), interval: interval)
    }
}

/// The finer thermal reading behind ProcessInfo.thermalState (which folds moderate and heavy into "fair"),
/// from the undocumented `com.apple.system.thermalpressurelevel` notification. No root needed.
public struct ThermalPressure: Sendable, Equatable {
    public var level: Int

    public init(level: Int) { self.level = level }

    public var label: String {
        switch level {
        case 0: "Nominal"
        case 1: "Moderate"
        case 2: "Heavy"
        case 3: "Trapping"
        case 4: "Sleeping"
        default: "Unknown"
        }
    }

    /// notify(3) isn't in Swift's Darwin module; the C functions are looked up in libSystem (status 0 = OK).
    public static func current() -> ThermalPressure? {
        typealias Register = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
        typealias GetState = @convention(c) (Int32, UnsafeMutablePointer<UInt64>) -> UInt32
        typealias Cancel = @convention(c) (Int32) -> UInt32
        let lib = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let r = dlsym(lib, "notify_register_check"), let g = dlsym(lib, "notify_get_state"), let c = dlsym(lib, "notify_cancel")
        else {
            return nil
        }
        let register = unsafeBitCast(r, to: Register.self)
        let getState = unsafeBitCast(g, to: GetState.self)
        let cancel = unsafeBitCast(c, to: Cancel.self)
        var token: Int32 = 0
        guard register("com.apple.system.thermalpressurelevel", &token) == 0 else { return nil }
        defer { _ = cancel(token) }
        var state: UInt64 = 0
        guard getState(token, &state) == 0 else { return nil }
        return ThermalPressure(level: Int(state))
    }
}

/// Thermal state and CPU load over time, drawn as fixed-width strips for `macx top` and game sessions.
public struct HeatTimeline: Sendable {
    public struct Sample: Sendable {
        public var time: Date
        public var level: ThermalLevel
        public var pressure: ThermalPressure?
        public var cpuPercent: Double

        public init(time: Date, level: ThermalLevel, pressure: ThermalPressure?, cpuPercent: Double) {
            self.time = time
            self.level = level
            self.pressure = pressure
            self.cpuPercent = cpuPercent
        }
    }

    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func add(_ s: Sample) { samples.append(s) }

    static func rank(_ l: ThermalLevel) -> Int {
        switch l {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public var peak: ThermalLevel? { samples.max { Self.rank($0.level) < Self.rank($1.level) }?.level }

    /// Time spent at serious or critical, measured to the next sample.
    public var secondsThrottled: TimeInterval {
        guard samples.count > 1 else { return 0 }
        return zip(samples, samples.dropFirst()).reduce(0) { sum, pair in
            pair.0.level.isThrottling ? sum + pair.1.time.timeIntervalSince(pair.0.time) : sum
        }
    }

    /// Splits the samples into at most `width` buckets, in order.
    func buckets(_ width: Int) -> [[Sample]] {
        guard !samples.isEmpty, width > 0 else { return [] }
        let n = min(width, samples.count)
        return (0..<n).map { i in Array(samples[(i * samples.count / n)..<((i + 1) * samples.count / n)]) }
    }

    /// One column per bucket; the hottest moment in each column wins.
    public func levelStrip(width: Int) -> String {
        let marks: [Character] = ["▁", "▃", "▅", "█"]
        return String(buckets(width).map { b in marks[b.map { Self.rank($0.level) }.max() ?? 0] })
    }

    public func loadStrip(width: Int) -> String {
        let marks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let top = max(100, samples.map(\.cpuPercent).max() ?? 100)
        return String(
            buckets(width).map { b in
                let avg = b.map(\.cpuPercent).reduce(0, +) / Double(max(b.count, 1))
                return marks[min(marks.count - 1, Int(avg / top * Double(marks.count - 1) + 0.5))]
            })
    }
}
