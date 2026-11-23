import Darwin
import Foundation

/// Parent and child links between running processes, read from the kernel with libproc.
public enum ProcessTree {
    public struct Entry: Sendable, Equatable, Codable {
        public var pid: Int
        public var ppid: Int
        public var path: String

        public init(pid: Int, ppid: Int, path: String) {
            self.pid = pid
            self.ppid = ppid
            self.path = path
        }
    }

    public static func snapshot() -> [Entry] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 32)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return pids.prefix(Int(got) / MemoryLayout<pid_t>.stride).compactMap { pid -> Entry? in
            guard pid > 0, let info = bsdInfo(pid) else { return nil }
            return Entry(pid: Int(pid), ppid: Int(info.pbi_ppid), path: path(of: pid))
        }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? info : nil
    }

    public static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    public static func descendants(of pid: Int, in table: [Entry]) -> [Int] {
        var children: [Int: [Int]] = [:]
        for e in table { children[e.ppid, default: []].append(e.pid) }
        var out: [Int] = []
        var queue = children[pid] ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !out.contains(next), next != pid else { continue }
            out.append(next)
            queue += children[next] ?? []
        }
        return out
    }

    /// The process, its parent, and so on up to launchd: who started what.
    public static func ancestry(of pid: Int, in table: [Entry]) -> [Entry] {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Entry] = []
        var current = byPID[pid]
        while let c = current, !out.contains(c) {
            out.append(c)
            current = c.ppid > 0 ? byPID[c.ppid] : nil
        }
        return out
    }

    /// Top-down, so a stopped process can't start new children while the rest are being stopped.
    /// launchd (pid 1) and macx itself are never included.
    public static func freezeOrder(root: Int, in table: [Entry]) -> [Int] {
        let me = Int(getpid())
        return ([root] + descendants(of: root, in: table)).filter { $0 > 1 && $0 != me }
    }

    /// Stops the process and everything under it. Re-reads the tree until no new children appear
    /// (a child started in the moment before its parent stopped). Returns the pids that were stopped.
    @discardableResult
    public static func freeze(root: Int) -> [Int] {
        var stopped: [Int] = []
        for _ in 0..<4 {
            let pending = freezeOrder(root: root, in: snapshot()).filter { !stopped.contains($0) }
            if pending.isEmpty { break }
            for pid in pending where kill(pid_t(pid), SIGSTOP) == 0 { stopped.append(pid) }
        }
        return stopped
    }

    public static func thaw(_ pids: [Int]) {
        for pid in pids { kill(pid_t(pid), SIGCONT) }
    }

    /// True when the kernel reports the process as stopped.
    public static func isStopped(_ pid: Int) -> Bool {
        // A stop signal is delivered asynchronously; give it a moment to land.
        for _ in 0..<50 {
            if let info = bsdInfo(pid_t(pid)), info.pbi_status == UInt32(SSTOP) { return true }
            usleep(2000)
        }
        return false
    }
}
