import Darwin
import Foundation

/// When the first-run setup window opens: once, until it's finished or skipped. Settings can run it again.
public enum FirstRun {
    public static let defaultsKey = "setupFinishedVersion"

    public static func shouldShowSetup(finished: String?) -> Bool { finished == nil }
}

/// What the setup steps check, read live while the window is open.
public struct SetupFacts: Sendable, Equatable {
    public enum Step: Sendable, CaseIterable { case fullDiskAccess, watch, notifications }
    public enum Notifications: Sendable, Equatable { case notAsked, allowed, denied }

    public var fullDiskAccess: Bool
    public var watch: WatchState
    public var notifications: Notifications

    public init(fullDiskAccess: Bool, watch: WatchState, notifications: Notifications) {
        self.fullDiskAccess = fullDiskAccess
        self.watch = watch
        self.notifications = notifications
    }

    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .fullDiskAccess: fullDiskAccess
        case .notifications: notifications == .allowed
        case .watch:
            switch watch {
            case .watching, .paused: true
            case .starting, .refused, .notRunning, .notInstalled: false
            }
        }
    }

    /// eslogger refused the watch: the Full Disk Access step needs doing (or redoing).
    public var watchNeedsFullDiskAccess: Bool {
        if case .refused = watch { return true }
        return false
    }
}

/// Is the Mac app open for this user? The background watch asks before it shows a notification itself: while
/// the app runs, the app posts alerts under its own notification permission. It looks for the app's process,
/// not a file, so nothing a stealer writes can silence the daemon's fallback.
public enum AppPresence {
    static let suffix = ".app/Contents/MacOS/macx"

    public static func isApp(path: String, arguments: [String], uid: uid_t, userUID: uid_t) -> Bool {
        guard uid == userUID, path.hasSuffix("/Macximesed" + suffix) else { return false }
        let rest = Array(arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        return rest.isEmpty || rest == ["app"]
    }

    /// argv from a `KERN_PROCARGS2` buffer: argc, the exec path, NUL padding, then argc strings.
    public static func parseProcargs2(_ data: Data) -> [String]? {
        guard data.count >= 4 else { return nil }
        let argc = data.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = data.startIndex + 4
        while i < data.endIndex, data[i] != 0 { i += 1 }  // exec path
        while i < data.endIndex, data[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while args.count < argc, i < data.endIndex {
            let start = i
            while i < data.endIndex, data[i] != 0 { i += 1 }
            args.append(String(decoding: data[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }

    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcargs2(Data(buf.prefix(size)))
    }

    static func uid(of pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? info.pbi_uid : nil
    }

    /// Whether `userUID` has the app open right now.
    public static func isAppRunning(userUID: uid_t) -> Bool {
        ProcessTree.snapshot().contains { e in
            guard e.path.hasSuffix(suffix), let uid = uid(of: Int32(e.pid)), let args = arguments(of: Int32(e.pid)) else { return false }
            return isApp(path: e.path, arguments: args, uid: uid, userUID: userUID)
        }
    }
}

/// Which new alerts the app shows as notifications: high and critical ones logged after it opened, at most
/// one every 10 seconds (the same throttle as the daemon), the most severe of each batch first.
public struct AppNotifications: Sendable {
    public struct Note: Sendable, Equatable {
        public var title: String
        public var body: String
    }

    let started: Date
    var throttle = NotificationThrottle()

    public init(started: Date) { self.started = started }

    public mutating func offer(_ records: [AlertRecord], now: Date = Date()) -> [Note] {
        let serious = records.filter { $0.severity >= .high && $0.rule != "frozen" && $0.time >= started }
            .sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.time > $1.time }
        var notes: [Note] = []
        for r in serious {
            if let body = throttle.offer(r.title, now: now) {
                notes.append(Note(title: "Macximesed: \(r.severity.label)", body: body))
            }
        }
        return notes
    }
}
