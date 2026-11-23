import Foundation
import Testing

@testable import MacxCore

@Suite("Process tree")
struct ProcessTreeTests {
    let table: [ProcessTree.Entry] = [
        .init(pid: 1, ppid: 0, path: "/sbin/launchd"),
        .init(pid: 100, ppid: 1, path: "/bin/zsh"),
        .init(pid: 200, ppid: 100, path: "/bin/bash"),
        .init(pid: 300, ppid: 200, path: "/usr/bin/curl"),
        .init(pid: 301, ppid: 200, path: "/bin/zsh"),
        .init(pid: 400, ppid: 301, path: "/tmp/payload"),
        .init(pid: 500, ppid: 1, path: "/Applications/Other.app/Contents/MacOS/Other"),
    ]

    @Test func descendantsAreAllLevelsDown() {
        #expect(ProcessTree.descendants(of: 200, in: table).sorted() == [300, 301, 400])
        #expect(ProcessTree.descendants(of: 400, in: table).isEmpty)
    }

    @Test func ancestryGoesUpToLaunchd() {
        #expect(ProcessTree.ancestry(of: 400, in: table).map(\.pid) == [400, 301, 200, 100, 1])
    }

    @Test func freezeOrderIsTopDownSoNothingCanSpawnMore() {
        // The process itself first (it can't start new children once stopped), then its children, then theirs.
        #expect(ProcessTree.freezeOrder(root: 200, in: table) == [200, 300, 301, 400])
    }

    @Test func neverFreezesLaunchdOrItself() {
        #expect(!ProcessTree.freezeOrder(root: 1, in: table).contains(1))
        let me = getpid()
        #expect(!ProcessTree.freezeOrder(root: Int(me), in: [.init(pid: Int(me), ppid: 1, path: "x")]).contains(Int(me)))
    }

    @Test func realSnapshotSeesOurOwnChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        defer { p.terminate() }
        let snap = ProcessTree.snapshot()
        #expect(snap.contains { $0.pid == Int(p.processIdentifier) && $0.ppid == Int(getpid()) })
        #expect(ProcessTree.descendants(of: Int(getpid()), in: snap).contains(Int(p.processIdentifier)))
    }

    @Test func freezingAndThawingARealChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        defer { p.terminate() }
        let frozen = ProcessTree.freeze(root: Int(p.processIdentifier))
        #expect(frozen == [Int(p.processIdentifier)])
        #expect(ProcessTree.isStopped(Int(p.processIdentifier)))
        ProcessTree.thaw(frozen)
        #expect(!ProcessTree.isStopped(Int(p.processIdentifier)))
    }

    @Test func listsDirectChildrenOfOneProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try p.run()
        defer { p.terminate() }
        #expect(ProcessTree.children(of: Int(getpid())).contains(Int(p.processIdentifier)))
        #expect(ProcessTree.children(of: Int(p.processIdentifier)).isEmpty)
    }
}
