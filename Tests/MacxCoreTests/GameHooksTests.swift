import Foundation
import Testing

@testable import MacxCore

@Suite("While playing: settings")
struct GameHooksTests {
    @Test func savesAndLoads() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("game-hooks.json")
        #expect(GameHooks.load(from: file) == GameHooks())  // nothing saved: everything off
        var h = GameHooks()
        h.focusStart = "Game on"
        h.focusEnd = "Game off"
        h.rawMouse = true
        h.gameNetwork = true
        h.socdApps = ["com.roblox.RobloxPlayer"]
        try h.save(to: file)
        #expect(GameHooks.load(from: file) == h)
    }

    @Test func shortcutNamesAreHandedOverAsOneArgument() {
        #expect(FocusShortcut.arguments("Game on; rm -rf ~") == ["run", "Game on; rm -rf ~"])
    }
}

@Suite("SOCD: the last key pressed wins")
struct SOCDTests {
    // Key codes on a US layout: A 0, D 2, W 13, S 1.
    let a: UInt16 = 0, d: UInt16 = 2, w: UInt16 = 13, s: UInt16 = 1

    @Test func pressingTheOppositeKeyReleasesTheFirst() {
        var r = SOCDResolver()
        #expect(r.handle(key: a, down: true) == [.pass])
        // D while A is held: A is let go (for the game), D goes through.
        #expect(r.handle(key: d, down: true) == [.post(key: a, down: false), .pass])
        // Letting go of D while A is still held: A comes back.
        #expect(r.handle(key: d, down: false) == [.pass, .post(key: a, down: true)])
        #expect(r.handle(key: a, down: false) == [.pass])
    }

    @Test func aKeyThatWasOverriddenIsSwallowedWhenReleased() {
        var r = SOCDResolver()
        _ = r.handle(key: a, down: true)
        _ = r.handle(key: d, down: true)
        // A was already let go for the game: its real release mustn't reach it twice.
        #expect(r.handle(key: a, down: false) == [.swallow])
        // Its key repeats while overridden are swallowed too.
        #expect(r.handle(key: d, down: false) == [.pass])
    }

    @Test func repeatsOfTheOverriddenKeyAreSwallowed() {
        var r = SOCDResolver()
        _ = r.handle(key: a, down: true)
        _ = r.handle(key: d, down: true)
        #expect(r.handle(key: a, down: true, isRepeat: true) == [.swallow])
        #expect(r.handle(key: d, down: true, isRepeat: true) == [.pass])
    }

    @Test func otherKeysAndTheOtherAxisAreLeftAlone() {
        var r = SOCDResolver()
        #expect(r.handle(key: 49, down: true) == [.pass])  // space
        _ = r.handle(key: a, down: true)
        #expect(r.handle(key: w, down: true) == [.pass])  // W doesn't fight A
        #expect(r.handle(key: s, down: true) == [.post(key: w, down: false), .pass])
    }

    @Test func resettingReleasesNothingTwice() {
        var r = SOCDResolver()
        _ = r.handle(key: a, down: true)
        _ = r.handle(key: d, down: true)
        // When the game loses focus: let go of what the game still thinks is down (only D), once.
        #expect(r.reset() == [.post(key: d, down: false)])
        #expect(r.reset().isEmpty)
    }
}

/// Plays the HID mice for the raw-mouse tests.
final class FakeMice: PointerDevices, @unchecked Sendable {
    var linear: [UInt64: Int?] = [1: 0, 2: nil]
    func mice() -> [UInt64] { Array(linear.keys).sorted() }
    func linearScaling(of id: UInt64) -> Int? { linear[id] ?? nil }
    func setLinearScaling(_ value: Int?, of id: UInt64) -> Bool {
        linear[id] = value
        return true
    }
}

@Suite("Raw mouse while playing")
struct RawMouseTests {
    @Test func turnsAccelerationOffAndPutsBackWhatWasThere() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("raw-mouse.json")
        let mice = FakeMice()
        try RawMouse.turnOff(mice, savingTo: file)
        #expect(mice.linear[1] == 1)
        #expect(mice.linear[2] == 1)
        #expect(RawMouse.restore(mice, from: file))
        #expect(mice.linear[1] == 0)
        #expect(mice.linear[2] == .some(nil))  // it had no value: none again
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!RawMouse.restore(mice, from: file))  // nothing left to put back
    }
}

@Suite("Game network: AWDL while a game runs")
struct GameNetworkTests {
    @Test func downOnlyWhileAPlayedGameIsAliveAndUpAfter() {
        #expect(GameNetwork.decide(enabled: true, gameAlive: true, weTookItDown: false) == .takeDown)
        #expect(GameNetwork.decide(enabled: true, gameAlive: true, weTookItDown: true) == .nothing)
        #expect(GameNetwork.decide(enabled: true, gameAlive: false, weTookItDown: true) == .bringUp)
        #expect(GameNetwork.decide(enabled: false, gameAlive: true, weTookItDown: true) == .bringUp)
        // Never brings up what someone else took down.
        #expect(GameNetwork.decide(enabled: false, gameAlive: false, weTookItDown: false) == .nothing)
    }

    @Test func readsPingSummaryAndTheGateway() {
        let ping = """
            PING 192.168.1.1 (192.168.1.1): 56 data bytes
            64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=3.214 ms

            --- 192.168.1.1 ping statistics ---
            30 packets transmitted, 29 packets received, 3.3% packet loss
            round-trip min/avg/max/stddev = 2.101/9.552/88.410/18.203 ms
            """
        let j = try! #require(Jitter.parse(ping))
        #expect(j.average == 9.552)
        #expect(j.worst == 88.410)
        #expect(j.spread == 18.203)
        #expect(j.lossPercent == 3.3)
        #expect(
            Jitter.gateway(fromRoute: "   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n")
                == "192.168.1.1")
        #expect(Jitter.gateway(fromRoute: "route: writing to routing socket: not in table") == nil)
    }
}

@Suite("Memory pressure and swap for the Performance tab")
struct MemoryStateTests {
    @Test func pressureLevelsReadLikeMacOSSays() {
        #expect(MemoryState.Pressure(level: 1) == .normal)
        #expect(MemoryState.Pressure(level: 2) == .warning)
        #expect(MemoryState.Pressure(level: 4) == .critical)
        #expect(MemoryState.Pressure(level: 0) == .normal)
        #expect(MemoryState.Pressure.warning.label == "Memory is tight")
    }

    @Test func theRealMacAnswers() throws {
        let m = try #require(MemoryState.current())
        #expect(m.physicalBytes > 0)
        #expect(m.swapUsedBytes <= m.swapTotalBytes || m.swapTotalBytes == 0)
    }

    @Test func busiestByMemoryUsesFootprint() {
        let uses = [
            CPUUse(pid: 1, uid: 501, path: "/a", cpuPercent: 50, memoryBytes: 100),
            CPUUse(pid: 2, uid: 501, path: "/b", cpuPercent: 1, memoryBytes: 900),
        ]
        #expect(CPUUse.byMemory(uses).map(\.pid) == [2, 1])
    }
}
