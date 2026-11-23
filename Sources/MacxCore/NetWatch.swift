import Darwin
import Foundation

/// One open network connection of a process: where it talks to.
public struct NetConnection: Sendable, Equatable, Hashable {
    public enum Proto: String, Sendable { case tcp, udp }

    public var proto: Proto
    public var localPort: Int
    public var remoteAddress: String
    public var remotePort: Int
    /// TCP state (established, syn-sent, ...); nil for UDP.
    public var state: String?

    public init(proto: Proto, localPort: Int, remoteAddress: String, remotePort: Int, state: String?) {
        self.proto = proto
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.state = state
    }

    public var endpoint: String {
        remoteAddress.contains(":") ? "[\(remoteAddress)]:\(remotePort)" : "\(remoteAddress):\(remotePort)"
    }

    public var isLoopback: Bool {
        remoteAddress == "::1" || remoteAddress.hasPrefix("127.") || remoteAddress == "::ffff:127.0.0.1"
    }
}

/// A process's sockets, read from the kernel with libproc (no lsof, no extra process).
/// Root can read any process; without root, only the user's own.
public enum NetConnections {
    /// nil when the process is gone or can't be read.
    public static func of(pid: pid_t) -> [NetConnection]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return nil }
        var out: [NetConnection] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard r == Int32(MemoryLayout<socket_fdinfo>.size), let c = connection(info.psi) else { continue }
            out.append(c)
        }
        return out
    }

    static func connection(_ s: socket_info) -> NetConnection? {
        guard s.soi_family == AF_INET || s.soi_family == AF_INET6 else { return nil }
        let ini: in_sockinfo
        var state: String?
        let proto: NetConnection.Proto
        switch (Int(s.soi_kind), s.soi_protocol) {
        case (Int(SOCKINFO_TCP), IPPROTO_TCP):
            ini = s.soi_proto.pri_tcp.tcpsi_ini
            state = tcpState(s.soi_proto.pri_tcp.tcpsi_state)
            proto = .tcp
        case (Int(SOCKINFO_IN), IPPROTO_UDP):
            ini = s.soi_proto.pri_in
            proto = .udp
        default: return nil
        }
        let remotePort = port(ini.insi_fport)
        guard remotePort != 0 else { return nil }  // listening or unconnected
        let address: String
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var a = ini.insi_faddr.ina_46.i46a_addr4
            address = withUnsafePointer(to: &a) { ntop(AF_INET, $0, Int(INET_ADDRSTRLEN)) }
        } else {
            var a = ini.insi_faddr.ina_6
            address = withUnsafePointer(to: &a) { ntop(AF_INET6, $0, Int(INET6_ADDRSTRLEN)) }
        }
        return NetConnection(proto: proto, localPort: port(ini.insi_lport), remoteAddress: address, remotePort: remotePort, state: state)
    }

    /// Ports are stored in network byte order in an int.
    static func port(_ p: Int32) -> Int { Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: p))) }

    static func ntop(_ family: Int32, _ addr: UnsafeRawPointer, _ size: Int) -> String {
        var buf = [CChar](repeating: 0, count: size)
        guard inet_ntop(family, addr, &buf, socklen_t(size)) != nil else { return "?" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func tcpState(_ s: Int32) -> String {
        let names = [
            "closed", "listen", "syn-sent", "syn-received", "established", "close-wait", "fin-wait-1", "closing", "last-ack",
            "fin-wait-2", "time-wait",
        ]
        return s >= 0 && Int(s) < names.count ? names[Int(s)] : "state \(s)"
    }
}

/// A new place a flagged process (or one it started) talked to.
public struct NetEvent: Sendable, Equatable {
    public var pid: Int
    public var path: String
    /// The alert rule that put the process under watch.
    public var reason: String
    public var connection: NetConnection
}

/// Follows processes behind alerts and reports each new remote endpoint once. Polling can't see
/// connections that open and close between two polls; the miss rate is measured in
/// research/evaluation/network-results.md.
public struct NetTracker {
    public struct Watched: Sendable, Equatable {
        public var root: Int
        public var reason: String
        public var path: String
        public var since: Date
    }

    let connections: (pid_t) -> [NetConnection]?
    let children: (Int) -> [Int]
    let followFor: TimeInterval
    let includeLoopback: Bool
    /// Report every new connection (keyed by local port too), not just each new remote.
    let perConnection: Bool
    public private(set) var watched: [Int: Watched] = [:]
    var seen: Set<String> = []

    public init(
        connections: @escaping (pid_t) -> [NetConnection]? = NetConnections.of(pid:),
        children: @escaping (Int) -> [Int] = ProcessTree.children(of:),
        followFor: TimeInterval = 300, includeLoopback: Bool = false, perConnection: Bool = false
    ) {
        self.perConnection = perConnection
        self.connections = connections
        self.children = children
        self.followFor = followFor
        self.includeLoopback = includeLoopback
    }

    public mutating func watch(pid: Int, reason: String, path: String, now: Date = Date()) {
        guard pid > 1, watched[pid] == nil else { return }
        watched[pid] = Watched(root: pid, reason: reason, path: path, since: now)
    }

    public mutating func poll(now: Date = Date()) -> [NetEvent] {
        // Pick up anything the watched processes started since the last poll.
        for (pid, w) in watched {
            for child in children(pid) where watched[child] == nil {
                watched[child] = Watched(root: w.root, reason: w.reason, path: ProcessTree.path(of: pid_t(child)), since: w.since)
            }
        }
        var out: [NetEvent] = []
        for pid in watched.keys.sorted() {
            guard let w = watched[pid] else { continue }
            guard now.timeIntervalSince(w.since) <= followFor, let conns = connections(pid_t(pid)) else {
                watched[pid] = nil
                continue
            }
            for c in conns where includeLoopback || !c.isLoopback {
                let key = "\(w.root) \(c.proto.rawValue) \(c.endpoint)" + (perConnection ? " \(pid) \(c.localPort)" : "")
                guard seen.insert(key).inserted else { continue }
                out.append(NetEvent(pid: pid, path: w.path.isEmpty ? "pid \(pid)" : w.path, reason: w.reason, connection: c))
            }
        }
        return out
    }
}
