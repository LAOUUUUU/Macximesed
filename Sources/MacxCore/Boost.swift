import Darwin
import Foundation

/// A preference value macx changes and puts back.
public enum PlistValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init?(_ any: Any?) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let s as String: self = .string(s)
        default: return nil
        }
    }

    var object: Any {
        switch self {
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        }
    }
}

/// Everything Boost and the Medium tier change on the Mac, behind one seam so tests change nothing.
public protocol SystemControl: Sendable {
    func read(domain: String, key: String) -> PlistValue?
    /// nil removes the key.
    func write(domain: String, key: String, value: PlistValue?) throws
    func setBackground(pid: Int32, on: Bool) throws
    /// The process's start time, so a reused pid is never mistaken for the original.
    func startTime(pid: Int32) -> UInt64?
    func spawn(_ args: [String]) throws -> Int32
    func kill(pid: Int32)
    func run(_ args: [String]) throws
}

public struct RealSystem: SystemControl {
    public init() {}

    /// `defaults` calls the global domain NSGlobalDomain; CFPreferences wants kCFPreferencesAnyApplication.
    static func cfDomain(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" || domain == "-g" ? kCFPreferencesAnyApplication : domain as CFString
    }

    public func read(domain: String, key: String) -> PlistValue? {
        PlistValue(CFPreferencesCopyAppValue(key as CFString, Self.cfDomain(domain)))
    }

    public func write(domain: String, key: String, value: PlistValue?) throws {
        let d = Self.cfDomain(domain)
        CFPreferencesSetAppValue(key as CFString, value?.object as CFPropertyList?, d)
        guard CFPreferencesAppSynchronize(d) else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// The same call taskpolicy -b / -B makes: background QoS (E cores, throttled I/O). Own processes only.
    public func setBackground(pid: Int32, on: Bool) throws {
        guard setpriority(PRIO_DARWIN_PROCESS, UInt32(pid), on ? PRIO_DARWIN_BG : 0) == 0 else { throw POSIXError(.EPERM) }
    }

    public func startTime(pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    public func spawn(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p.processIdentifier
    }

    public func kill(pid: Int32) { _ = Darwin.kill(pid, SIGTERM) }

    public func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}

/// Every change Boost or the Medium tier makes, written to disk *before* it's made, so it can always be undone,
/// even after a crash (`macx boost off`, or the next macx run).
public struct TweakLedger: Codable, Sendable {
    public enum Change: Codable, Sendable, Equatable {
        case setting(domain: String, key: String, before: PlistValue?, after: PlistValue)
        case background(pid: Int32, start: UInt64)
        case awake(pid: Int32)
        case command(apply: [String], undo: [String])

        public var label: String {
            switch self {
            case .setting(let d, let k, _, let a): "\(d) \(k) = \(a.object)"
            case .background(let pid, _): "pid \(pid) on background priority"
            case .awake: "keeping the Mac awake (caffeinate)"
            case .command(let a, _): a.joined(separator: " ")
            }
        }
    }

    public struct RestoreReport: Sendable {
        public var restored: [Change]
        public var failed: [(Change, String)]
    }

    public var purpose: String
    public var created: Date
    public var changes: [Change]
    public var file: URL

    enum CodingKeys: String, CodingKey { case purpose, created, changes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        purpose = try c.decode(String.self, forKey: .purpose)
        created = try c.decode(Date.self, forKey: .created)
        changes = try c.decode([Change].self, forKey: .changes)
        file = URL(fileURLWithPath: "/")
    }

    init(purpose: String, file: URL) {
        self.purpose = purpose
        self.created = Date()
        self.changes = []
        self.file = file
    }

    public static func open(at file: URL, purpose: String) throws -> TweakLedger {
        let l = TweakLedger(purpose: purpose, file: file)
        try l.save()
        return l
    }

    public static func load(at file: URL) -> TweakLedger? {
        guard let data = try? Data(contentsOf: file), var l = try? JSONDecoder().decode(TweakLedger.self, from: data) else { return nil }
        l.file = file
        return l
    }

    func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: file, options: .atomic)
    }

    /// Record, then make the change. If making it fails, the record is dropped again.
    mutating func record(_ change: Change, perform: () throws -> Void) throws {
        changes.append(change)
        try save()
        do {
            try perform()
        } catch {
            changes.removeLast()
            try? save()
            throw error
        }
    }

    public mutating func setDefault(domain: String, key: String, to value: PlistValue, system: SystemControl) throws {
        let before = system.read(domain: domain, key: key)
        guard before != value else { return }
        try record(.setting(domain: domain, key: key, before: before, after: value)) {
            try system.write(domain: domain, key: key, value: value)
        }
    }

    public mutating func demote(pid: Int32, system: SystemControl) throws {
        guard let start = system.startTime(pid: pid) else { return }
        try record(.background(pid: pid, start: start)) { try system.setBackground(pid: pid, on: true) }
    }

    @discardableResult
    public mutating func keepAwake(system: SystemControl) throws -> Int32 {
        let pid = try system.spawn(["/usr/bin/caffeinate", "-dis"])
        try record(.awake(pid: pid)) {}
        return pid
    }

    public mutating func runCommand(_ apply: [String], undo: [String], system: SystemControl) throws {
        try record(.command(apply: apply, undo: undo)) { try system.run(apply) }
    }

    /// Puts everything back, newest first. A failure doesn't stop the rest; a ledger with failures is kept.
    public func restore(system: SystemControl) -> RestoreReport {
        var restored: [Change] = []
        var failed: [(Change, String)] = []
        for change in changes.reversed() {
            do {
                switch change {
                case .setting(let d, let k, let before, _): try system.write(domain: d, key: k, value: before)
                case .background(let pid, let start):
                    if system.startTime(pid: pid) == start { try system.setBackground(pid: pid, on: false) }
                case .awake(let pid): system.kill(pid: pid)
                case .command(_, let undo): try system.run(undo)
                }
                restored.append(change)
            } catch {
                failed.append((change, "\(error)"))
            }
        }
        if failed.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            var left = self
            left.changes = failed.map(\.0).reversed()
            try? left.save()
        }
        return RestoreReport(restored: restored, failed: failed)
    }
}

/// CPU used by one process over the last sampling interval (100% = one core).
public struct CPUUse: Sendable, Equatable {
    public var pid: Int32
    public var uid: uid_t
    public var path: String
    public var cpuPercent: Double

    public init(pid: Int32, uid: uid_t, path: String, cpuPercent: Double) {
        self.pid = pid
        self.uid = uid
        self.path = path
        self.cpuPercent = cpuPercent
    }

    public var name: String {
        // An app's helper reads better as "Slack Helper (Renderer)" than its binary path.
        (path as NSString).lastPathComponent
    }
}

public struct BoostPlan: Sendable {
    public struct Setting: Sendable, Equatable {
        public var domain: String
        public var key: String
        public var value: PlistValue
        public var why: String
    }

    public var focus: URL?
    public var demote: [CPUUse]
    public var settings: [Setting]
    public var keepAwake: Bool
}

/// Boost: give the focus app (a game, say) more of the Mac by taking work away from everything else. Clocks
/// can't be raised on Apple silicon; this only moves the competition aside, and every change is undone.
public enum Boost {
    public enum Problem: Error, Equatable { case alreadyOn }

    public static let defaultLedger = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Macximesed/boost.json")
    static let applePrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/"]

    public static func plan(
        focus: URL?, focusBundleID: String? = nil, samples: [CPUUse], uid: uid_t, selfPID: Int32, protected: Set<Int32> = [],
        limit: Int = 5, threshold: Double = 10
    ) -> BoostPlan {
        let focusPrefix = focus.map { $0.standardizedFileURL.path + "/" }
        let demote =
            samples
            .filter { s in
                s.uid == uid && s.pid != selfPID && !protected.contains(s.pid) && s.cpuPercent >= threshold
                    && !applePrefixes.contains(where: { s.path.hasPrefix($0) }) && !(focusPrefix.map { s.path.hasPrefix($0) } ?? false)
            }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
        var settings = [
            BoostPlan.Setting(
                domain: "com.apple.universalaccess", key: "reduceTransparency", value: .bool(true), why: "less window-blur work for the GPU"
            ),
            BoostPlan.Setting(domain: "com.apple.universalaccess", key: "reduceMotion", value: .bool(true), why: "fewer animations"),
        ]
        if let id = focusBundleID {
            settings.append(
                BoostPlan.Setting(domain: id, key: "NSAppSleepDisabled", value: .bool(true), why: "App Nap off for the focus app"))
        }
        return BoostPlan(focus: focus, demote: Array(demote), settings: settings, keepAwake: true)
    }

    /// Applies a plan, recording each change first. Refuses if a Boost is already on (turn it off first).
    @discardableResult
    public static func apply(_ plan: BoostPlan, ledgerAt file: URL = defaultLedger, system: SystemControl = RealSystem()) throws
        -> TweakLedger
    {
        guard TweakLedger.load(at: file) == nil else { throw Problem.alreadyOn }
        var ledger = try TweakLedger.open(at: file, purpose: "boost")
        for p in plan.demote { try? ledger.demote(pid: p.pid, system: system) }
        for s in plan.settings { try? ledger.setDefault(domain: s.domain, key: s.key, to: s.value, system: system) }
        if plan.keepAwake { try ledger.keepAwake(system: system) }
        return ledger
    }
}
