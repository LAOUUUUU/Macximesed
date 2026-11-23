import Darwin
import Foundation
import Testing

@testable import MacxCore

@Suite("Network watching")
struct NetWatchTests {
    /// A TCP listener on 127.0.0.1 and a client connected to it, both in this test process.
    func localPair() throws -> (listener: Int32, client: Int32, port: Int) {
        let l = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard bind(l, sa, len) == 0, listen(l, 4) == 0, getsockname(l, sa, &len) == 0 else { throw POSIXError(.EADDRINUSE) }
            }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let c = socket(AF_INET, SOCK_STREAM, 0)
        try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard connect(c, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else { throw POSIXError(.ECONNREFUSED) }
            }
        }
        return (l, c, port)
    }

    @Test func readsThisProcesssOwnTCPConnection() throws {
        let pair = try localPair()
        defer {
            close(pair.client)
            close(pair.listener)
        }
        let conns = try #require(NetConnections.of(pid: getpid()))
        #expect(conns.contains { $0.proto == .tcp && $0.remoteAddress == "127.0.0.1" && $0.remotePort == pair.port })
        // The listener has no remote end and isn't a connection.
        #expect(!conns.contains { $0.localPort == pair.port && $0.remotePort == 0 })
    }

    @Test func unreadableProcessGivesNil() {
        #expect(NetConnections.of(pid: 999_999) == nil)
    }

    @Test func endpointFormatting() {
        let v4 = NetConnection(proto: .tcp, localPort: 5000, remoteAddress: "1.2.3.4", remotePort: 443, state: "established")
        let v6 = NetConnection(proto: .udp, localPort: 5001, remoteAddress: "2001:db8::1", remotePort: 53, state: nil)
        #expect(v4.endpoint == "1.2.3.4:443")
        #expect(v6.endpoint == "[2001:db8::1]:53")
        #expect(v4.isLoopback == false)
        #expect(NetConnection(proto: .tcp, localPort: 1, remoteAddress: "::1", remotePort: 2, state: nil).isLoopback)
    }

    @Test func trackerReportsEachEndpointOnceAndFollowsChildren() {
        let a = NetConnection(proto: .tcp, localPort: 50000, remoteAddress: "203.0.113.5", remotePort: 443, state: "established")
        let b = NetConnection(proto: .tcp, localPort: 50001, remoteAddress: "198.51.100.7", remotePort: 80, state: "established")
        var table: [Int: [NetConnection]] = [100: [a]]
        var children: [Int: [Int]] = [:]
        var tracker = NetTracker(
            connections: { pid in table[Int(pid)] },
            children: { pid in children[pid] ?? [] })
        tracker.watch(pid: 100, reason: "fake-password-prompt", path: "/tmp/x")

        let first = tracker.poll(now: Date(timeIntervalSince1970: 0))
        #expect(first.map(\.connection) == [a])
        #expect(first.first?.reason == "fake-password-prompt")
        // Same connection again: nothing new.
        #expect(tracker.poll(now: Date(timeIntervalSince1970: 1)).isEmpty)

        // A child it started connects somewhere else: reported, tied to the child.
        children[100] = [101]
        table[101] = [b]
        let second = tracker.poll(now: Date(timeIntervalSince1970: 2))
        #expect(second.map(\.connection) == [b])
        #expect(second.first?.pid == 101)

        // The same remote from a new local port (a reconnect) isn't reported again.
        table[100] = [NetConnection(proto: .tcp, localPort: 50009, remoteAddress: "203.0.113.5", remotePort: 443, state: "established")]
        #expect(tracker.poll(now: Date(timeIntervalSince1970: 3)).isEmpty)
    }

    @Test func trackerDropsGoneAndExpiredProcesses() {
        var alive = true
        var tracker = NetTracker(
            connections: { _ in alive ? [] : nil }, children: { _ in [] }, followFor: 60)
        tracker.watch(pid: 7, reason: "r", path: "/p", now: Date(timeIntervalSince1970: 0))
        _ = tracker.poll(now: Date(timeIntervalSince1970: 10))
        #expect(tracker.watched.count == 1)
        _ = tracker.poll(now: Date(timeIntervalSince1970: 61))
        #expect(tracker.watched.isEmpty)

        tracker.watch(pid: 8, reason: "r", path: "/p", now: Date(timeIntervalSince1970: 100))
        alive = false
        _ = tracker.poll(now: Date(timeIntervalSince1970: 101))
        #expect(tracker.watched.isEmpty)
    }

    @Test func loopbackIsSkippedByDefault() {
        let lo = NetConnection(proto: .tcp, localPort: 1, remoteAddress: "127.0.0.1", remotePort: 8080, state: "established")
        var tracker = NetTracker(connections: { _ in [lo] }, children: { _ in [] })
        tracker.watch(pid: 5, reason: "r", path: "/p")
        #expect(tracker.poll(now: Date()).isEmpty)
        var all = NetTracker(connections: { _ in [lo] }, children: { _ in [] }, includeLoopback: true)
        all.watch(pid: 5, reason: "r", path: "/p")
        #expect(all.poll(now: Date()).count == 1)
    }

    @Test func perConnectionModeReportsReconnects() {
        var table: [Int: [NetConnection]] = [
            5: [NetConnection(proto: .tcp, localPort: 1, remoteAddress: "203.0.113.5", remotePort: 443, state: nil)]
        ]
        var tracker = NetTracker(connections: { table[Int($0)] }, children: { _ in [] }, perConnection: true)
        tracker.watch(pid: 5, reason: "r", path: "/p")
        #expect(tracker.poll().count == 1)
        table[5] = [NetConnection(proto: .tcp, localPort: 2, remoteAddress: "203.0.113.5", remotePort: 443, state: nil)]
        #expect(tracker.poll().count == 1)
    }
}
