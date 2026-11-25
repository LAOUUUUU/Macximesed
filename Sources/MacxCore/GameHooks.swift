import Foundation
import IOKit.hid

// Performance round 2 (research/performance-v2/RESEARCH.md): what happens while you play a game started with Play.

/// The "While playing" settings, in the user's Application Support. Everything is off until switched on.
public struct GameHooks: Codable, Sendable, Equatable {
    /// Shortcuts (from the Shortcuts app) run when a game starts and ends, e.g. to set Do Not Disturb.
    public var focusStart: String?
    public var focusEnd: String?
    /// Pointer acceleration off while playing (put back afterwards).
    public var rawMouse = false
    /// AWDL (AirDrop/AirPlay radio) off while playing; done by the background watch, which runs as root.
    public var gameNetwork = false
    /// Apps (bundle IDs) where SOCD is on: of two opposite movement keys, the last one pressed wins.
    public var socdApps: [String] = []

    public init() {}

    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Macximesed/game-hooks.json")
    }

    public static func load(from file: URL = GameHooks.file()) -> GameHooks {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(GameHooks.self, from: $0) } ?? GameHooks()
    }

    public func save(to file: URL = GameHooks.file()) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: file, options: .atomic)
    }
}

/// Runs one of the user's shortcuts (`shortcuts run NAME`). The name is one argument, never a shell string.
public enum FocusShortcut {
    public static func arguments(_ name: String) -> [String] { ["run", name] }

    @discardableResult
    public static func run(_ name: String?, runner: CommandRunner = ProcessRunner(timeout: 20)) -> Bool {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return (try? runner.run("/usr/bin/shortcuts", arguments(name))) != nil
    }
}

// MARK: - SOCD

/// SOCD ("snap tap"): when both keys of an opposite pair are held, the game sees only the one pressed last; letting
/// go of it brings the other back. Pure logic, fed by the app's keyboard tap. Pairs: A/D and W/S (US key codes).
public struct SOCDResolver: Sendable {
    public enum Action: Sendable, Equatable {
        /// Let the real event through.
        case pass
        /// Drop the real event (the game already had it from us).
        case swallow
        /// Post a made-up event.
        case post(key: UInt16, down: Bool)
    }

    public static let defaultPairs: [(UInt16, UInt16)] = [(0, 2), (13, 1)]

    var opposite: [UInt16: UInt16] = [:]
    /// Keys physically held.
    var held: Set<UInt16> = []
    /// Keys held but let go for the game, because their opposite was pressed later.
    var overridden: Set<UInt16> = []

    public init(pairs: [(UInt16, UInt16)] = SOCDResolver.defaultPairs) {
        for (x, y) in pairs {
            opposite[x] = y
            opposite[y] = x
        }
    }

    public mutating func handle(key: UInt16, down: Bool, isRepeat: Bool = false) -> [Action] {
        guard let other = opposite[key] else { return [.pass] }
        if down {
            if isRepeat { return overridden.contains(key) ? [.swallow] : [.pass] }
            held.insert(key)
            overridden.remove(key)
            if held.contains(other), !overridden.contains(other) {
                overridden.insert(other)
                return [.post(key: other, down: false), .pass]
            }
            return [.pass]
        }
        held.remove(key)
        if overridden.remove(key) != nil { return [.swallow] }
        if held.contains(other), overridden.remove(other) != nil { return [.pass, .post(key: other, down: true)] }
        return [.pass]
    }

    /// When the game stops being the front app: let go of what it still thinks is down, and forget everything.
    public mutating func reset() -> [Action] {
        let downForGame = held.subtracting(overridden).sorted()
        held = []
        overridden = []
        return downForGame.map { .post(key: $0, down: false) }
    }
}

// MARK: - Raw mouse

/// The mice the HID system knows, and their linear-scaling switch (`kIOHIDUseLinearScalingMouseAccelerationKey`,
/// macOS 14 and later: 1 = no pointer acceleration). Behind a protocol so tests don't touch the real mouse.
public protocol PointerDevices: Sendable {
    func mice() -> [UInt64]
    func linearScaling(of id: UInt64) -> Int?
    @discardableResult func setLinearScaling(_ value: Int?, of id: UInt64) -> Bool
}

public struct HIDPointerDevices: PointerDevices {
    public init() {}
    static var key: CFString { kIOHIDUseLinearScalingMouseAccelerationKey as CFString }

    func services() -> [(UInt64, IOHIDServiceClient)] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return all.compactMap { s in
            guard IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0,
                (IOHIDServiceClientCopyProperty(s, kIOHIDBuiltInKey as CFString) as? Bool) != true,  // not the trackpad
                let id = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value
            else { return nil }
            return (id, s)
        }
    }

    public func mice() -> [UInt64] { services().map(\.0) }

    public func linearScaling(of id: UInt64) -> Int? {
        guard let s = services().first(where: { $0.0 == id })?.1 else { return nil }
        return (IOHIDServiceClientCopyProperty(s, Self.key) as? NSNumber)?.intValue
    }

    @discardableResult
    public func setLinearScaling(_ value: Int?, of id: UInt64) -> Bool {
        guard let s = services().first(where: { $0.0 == id })?.1 else { return false }
        // No earlier value: 0 is macOS's default (acceleration on).
        return IOHIDServiceClientSetProperty(s, Self.key, NSNumber(value: value ?? 0))
    }
}

/// Pointer acceleration off for the game, with what was there saved first (so a crash can't leave it off).
public enum RawMouse {
    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Macximesed/raw-mouse.json")
    }

    struct Saved: Codable { var before: [String: Int?] }

    public static func turnOff(_ mice: PointerDevices = HIDPointerDevices(), savingTo file: URL = RawMouse.file()) throws {
        var before: [String: Int?] = [:]
        for id in mice.mice() { before[String(id)] = mice.linearScaling(of: id) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Saved(before: before)).write(to: file, options: .atomic)
        for id in mice.mice() { mice.setLinearScaling(1, of: id) }
    }

    /// Puts back what `turnOff` saved. False when there was nothing to put back.
    @discardableResult
    public static func restore(_ mice: PointerDevices = HIDPointerDevices(), from file: URL = RawMouse.file()) -> Bool {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return false }
        for (key, value) in saved.before { if let id = UInt64(key) { mice.setLinearScaling(value, of: id) } }
        try? FileManager.default.removeItem(at: file)
        return true
    }
}

// MARK: - Game network

/// AWDL (`awdl0`, AirDrop and AirPlay discovery) hops the Wi-Fi radio to other channels every 1-2 s, stalling traffic
/// for ~80-90 ms. The root background watch takes it down while a game started with Play is running and brings it
/// back afterwards. It only ever brings up what it took down itself.
public enum GameNetwork {
    public enum Step: Sendable, Equatable { case takeDown, bringUp, nothing }

    public static func decide(enabled: Bool, gameAlive: Bool, weTookItDown: Bool) -> Step {
        if enabled, gameAlive { return weTookItDown ? .nothing : .takeDown }
        return weTookItDown ? .bringUp : .nothing
    }

    public static func apply(_ step: Step, runner: CommandRunner = ProcessRunner(timeout: 10)) -> Bool {
        switch step {
        case .takeDown: (try? runner.run("/sbin/ifconfig", ["awdl0", "down"])) != nil
        case .bringUp: (try? runner.run("/sbin/ifconfig", ["awdl0", "up"])) != nil
        case .nothing: true
        }
    }
}

/// Wi-Fi jitter to the router: `ping` the default gateway and read its summary. Shows whether Game network helps.
public struct Jitter: Sendable, Equatable {
    public var average: Double
    public var worst: Double
    public var spread: Double
    public var lossPercent: Double

    public static func parse(_ ping: String) -> Jitter? {
        guard let line = ping.split(separator: "\n").first(where: { $0.contains("min/avg/max/stddev") }),
            let numbers = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first
        else { return nil }
        let v = numbers.split(separator: "/").compactMap { Double($0) }
        guard v.count == 4 else { return nil }
        let loss =
            ping.split(separator: "\n").first { $0.contains("packet loss") }?.split(separator: ",")
            .first { $0.contains("packet loss") }?.trimmingCharacters(in: .whitespaces).split(separator: "%").first
            .flatMap { Double($0) } ?? 0
        return Jitter(average: v[1], worst: v[2], spread: v[3], lossPercent: loss)
    }

    public static func gateway(fromRoute text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("gateway:") }
            .map { String($0.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces) }
    }

    /// About 6 s: 30 pings, 0.2 s apart.
    public static func measure(runner: CommandRunner = ProcessRunner(timeout: 20)) -> Jitter? {
        guard let route = try? runner.run("/sbin/route", ["-n", "get", "default"]), let gw = gateway(fromRoute: route) else { return nil }
        return (try? runner.run("/sbin/ping", ["-c", "30", "-i", "0.2", "-q", gw])).flatMap(parse)
    }
}
