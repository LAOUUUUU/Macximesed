import Foundation
import Testing

@testable import MacxCore

// MARK: - Fixtures

func machO(cpu: UInt32) -> Data {
    var d = Data([0xCF, 0xFA, 0xED, 0xFE])  // MH_MAGIC_64, little-endian
    withUnsafeBytes(of: cpu.littleEndian) { d.append(contentsOf: $0) }
    d.append(Data(count: 24))
    return d
}

func fatMachO(cpus: [UInt32]) -> Data {
    var d = Data([0xCA, 0xFE, 0xBA, 0xBE])  // FAT_MAGIC, big-endian
    withUnsafeBytes(of: UInt32(cpus.count).bigEndian) { d.append(contentsOf: $0) }
    for cpu in cpus {
        withUnsafeBytes(of: cpu.bigEndian) { d.append(contentsOf: $0) }
        d.append(Data(count: 16))  // subtype, offset, size, align
    }
    return d
}

let cpuARM64: UInt32 = 0x0100_000C
let cpuX86_64: UInt32 = 0x0100_0007

extension TempDir {
    @discardableResult
    func app(
        _ path: String, id: String, name: String? = nil, version: String = "1.0",
        binary: Data = machO(cpu: cpuARM64), appStore: Bool = false
    ) throws -> URL {
        let app = url.appendingPathComponent(path)
        let contents = app.appendingPathComponent("Contents")
        let exe = "Main"
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": exe, "CFBundleShortVersionString": version]
        if let name { info["CFBundleName"] = name }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try binary.write(to: contents.appendingPathComponent("MacOS/\(exe)"))
        if appStore {
            try file("\(path)/Contents/_MASReceipt/receipt", "r")
        }
        return app
    }
}

// MARK: - Mach-O

@Suite("Mach-O architectures")
struct MachOTests {
    @Test func thinBinaries() {
        #expect(MachO.architectures(of: machO(cpu: cpuARM64)) == [.arm64])
        #expect(MachO.architectures(of: machO(cpu: cpuX86_64)) == [.x86_64])
    }

    @Test func universalBinary() {
        #expect(MachO.architectures(of: fatMachO(cpus: [cpuX86_64, cpuARM64])) == [.arm64, .x86_64])
    }

    @Test func notMachO() {
        #expect(MachO.architectures(of: Data("#!/bin/sh\n".utf8)).isEmpty)
        #expect(MachO.architectures(of: Data()).isEmpty)
    }

    @Test func kindLabelsOnAppleSilicon() {
        #expect(AppArch.kind([.arm64], hostIsARM: true) == "Apple silicon")
        #expect(AppArch.kind([.x86_64], hostIsARM: true) == "Intel (Rosetta)")
        #expect(AppArch.kind([.arm64, .x86_64], hostIsARM: true) == "Universal")
        #expect(AppArch.kind([], hostIsARM: true) == "unknown")
    }

    @Test func kindLabelsOnIntelMacs() {
        #expect(AppArch.kind([.x86_64], hostIsARM: false) == "Intel")
        #expect(AppArch.kind([.arm64], hostIsARM: false) == "Apple silicon only (can't run here)")
        #expect(AppArch.kind([.arm64, .x86_64], hostIsARM: false) == "Universal")
    }
}

// MARK: - Scanning

@Suite("App discovery")
struct AppDiscoveryTests {
    @Test func keepsTopLevelAppsAnywhereAndDropsHelpersSystemLibraryAndTrash() {
        let out = """
            /Applications/Game.app
            /Volumes/External/Apps/Editor.app
            /Users/someone/Documents/Builds/MyTool.app
            /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app
            /System/Applications/Chess.app
            /Users/someone/Library/Application Support/Steam/Steam Helper.app
            /Users/someone/.Trash/Old.app
            /Users/someone/project/dist/thing.service
            """
        #expect(
            AppScanner.parseAppPaths(out).map(\.path) == [
                "/Applications/Game.app", "/Volumes/External/Apps/Editor.app", "/Users/someone/Documents/Builds/MyTool.app",
            ])
        #expect(AppScanner.parseAppPaths(out, includeSystem: true).map(\.path).contains("/System/Applications/Chess.app"))
    }
}

@Suite("App scanning")
struct AppScanTests {
    @Test func findsAppsAtTopLevelAndOneFolderDown() throws {
        let tmp = try TempDir()
        try tmp.app("Applications/Game.app", id: "com.example.game", name: "Game", version: "2.1")
        try tmp.app("Applications/Vendor Suite/Tool.app", id: "com.vendor.tool", binary: machO(cpu: cpuX86_64))
        try tmp.app("Applications/Vendor Suite/Deep/TooDeep.app", id: "com.vendor.deep")
        try tmp.file("Applications/readme.txt")

        let apps = AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in nil })
        #expect(apps.map(\.bundleID) == ["com.example.game", "com.vendor.tool"])
        let game = apps[0]
        #expect(game.name == "Game")
        #expect(game.version == "2.1")
        #expect(game.architectures == [.arm64])
        #expect(game.bytes > 0)
        #expect(apps[1].name == "Tool")  // falls back to the folder name
        #expect(apps[1].architectures == [.x86_64])
    }

    @Test func findsAppsInsideFoldersWithDotsInTheirName() throws {
        let tmp = try TempDir()
        try tmp.app("Applications/Cisco Packet Tracer 9.0.1/Cisco Packet Tracer 9.0.1.app", id: "com.netacad.PacketTracer9.0.1")
        let apps = AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in nil })
        #expect(apps.map(\.bundleID) == ["com.netacad.PacketTracer9.0.1"])
    }

    @Test func estimatesLastUseFromTheAppsOwnFilesWhenSpotlightHasNoDate() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home")
        try tmp.app("Applications/Steam.app", id: "com.valvesoftware.steam", name: "Steam")
        let prefs = try tmp.file("home/Library/Preferences/com.valvesoftware.steam.plist")
        let support = try tmp.file("home/Library/Application Support/com.valvesoftware.steam/registry.vdf")
        let older = Date(timeIntervalSince1970: 1_780_000_000)
        let newer = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: prefs.path)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: support.path)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: support.deletingLastPathComponent().path)

        let apps = AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in nil }, home: home)
        #expect(apps[0].lastUsed == newer)
        #expect(apps[0].lastUsedIsEstimate)

        let spotlight = Date(timeIntervalSince1970: 1_795_000_000)
        let exact = AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in spotlight }, home: home)
        #expect(exact[0].lastUsed == spotlight)
        #expect(!exact[0].lastUsedIsEstimate)
    }

    @Test func marksAppleAndAppStoreApps() throws {
        let tmp = try TempDir()
        try tmp.app("A/GarageBand.app", id: "com.apple.garageband10", appStore: true)
        try tmp.app("A/Chess.app", id: "com.apple.Chess")
        try tmp.app("A/Thing.app", id: "com.example.thing", appStore: true)
        let byID = Dictionary(
            uniqueKeysWithValues: AppScanner.scan([tmp.url.appendingPathComponent("A")], lastUsed: { _ in nil }).map { ($0.bundleID, $0) })
        #expect(byID["com.apple.garageband10"]?.isApple == true)
        #expect(byID["com.apple.garageband10"]?.fromAppStore == true)
        #expect(byID["com.apple.Chess"]?.fromAppStore == false)
        #expect(byID["com.example.thing"]?.isApple == false)
    }

    @Test func usesLastUsedProvider() throws {
        let tmp = try TempDir()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try tmp.app("A/Old.app", id: "com.example.old")
        let apps = AppScanner.scan([tmp.url.appendingPathComponent("A")], lastUsed: { _ in when })
        #expect(apps.first?.lastUsed == when)
    }

    @Test func unusedNeedsAKnownOldDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func app(_ id: String, _ daysAgo: Double?) -> AppInfo {
            AppInfo(
                url: URL(fileURLWithPath: "/Applications/\(id).app"), bundleID: id, name: id, version: nil,
                bytes: 1, architectures: [.arm64], lastUsed: daysAgo.map { now.addingTimeInterval(-$0 * 86400) },
                isApple: false, fromAppStore: false)
        }
        let apps = [app("old", 120), app("recent", 10), app("unknown", nil)]
        #expect(AppScanner.unused(apps, olderThanDays: 90, now: now).map(\.bundleID) == ["old"])
    }
}

// MARK: - Leftovers and uninstall

@Suite("App leftovers and uninstall")
struct AppUninstallTests {
    func homeWithLeftovers() throws -> TempDir {
        let tmp = try TempDir()
        try tmp.app("Applications/Game.app", id: "com.example.game", name: "Game")
        try tmp.file("home/Library/Application Support/com.example.game/save.dat")
        try tmp.file("home/Library/Application Support/Game/config.json")
        try tmp.file("home/Library/Caches/com.example.game/c")
        try tmp.file("home/Library/Preferences/com.example.game.plist")
        try tmp.file("home/Library/Preferences/ByHost/com.example.game.1234-ABCD.plist")
        try tmp.file("home/Library/Saved Application State/com.example.game.savedState/data")
        try tmp.file("home/Library/HTTPStorages/com.example.game/x")
        try tmp.file("home/Library/LaunchAgents/com.example.game.updater.plist")
        try tmp.file("home/Library/Containers/com.example.game/Data/x")
        // Another app's files must be left alone.
        try tmp.file("home/Library/Application Support/com.example.gamepad/keep")
        try tmp.file("home/Library/Preferences/com.example.gamepad.plist")
        try tmp.file("home/Library/Application Support/Gamer/keep")
        return tmp
    }

    func game(_ tmp: TempDir) -> AppInfo {
        AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in nil })[0]
    }

    @Test func findsLeftoversByExactBundleIDOnlyByDefault() throws {
        let tmp = try homeWithLeftovers()
        let all = AppLeftovers.find(for: game(tmp), home: tmp.url.appendingPathComponent("home"))
        #expect(
            Set(all.map(\.lastPathComponent)) == [
                "com.example.game", "com.example.game.plist", "com.example.game.1234-ABCD.plist",
                "com.example.game.savedState", "com.example.game.updater.plist",
            ])
        // Application Support, Caches, HTTPStorages and Containers each have a com.example.game folder.
        #expect(all.filter { $0.lastPathComponent == "com.example.game" }.count == 4)
        #expect(!all.contains { $0.path.contains("gamepad") || $0.path.contains("Gamer") })
    }

    @Test func nameMatchesAreSeparateAndOptIn() throws {
        let tmp = try homeWithLeftovers()
        let home = tmp.url.appendingPathComponent("home")
        #expect(AppLeftovers.nameMatches(for: game(tmp), home: home).map(\.lastPathComponent) == ["Game"])
        let plain = try AppUninstaller.plan(game(tmp), home: home, runningBundleIDs: [])
        #expect(!plain.paths.contains { $0.lastPathComponent == "Game" })
        let withNames = try AppUninstaller.plan(game(tmp), home: home, runningBundleIDs: [], includeNameMatches: true)
        #expect(withNames.paths.contains { $0.lastPathComponent == "Game" })
    }

    @Test func uninstallMovesAppAndLeftoversAndUndoBringsThemBack() throws {
        let tmp = try homeWithLeftovers()
        let home = tmp.url.appendingPathComponent("home")
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        let plan = try AppUninstaller.plan(game(tmp), home: home, runningBundleIDs: [])
        let batch = try AppUninstaller.run(plan, store: store)
        #expect(!tmp.exists("Applications/Game.app"))
        #expect(!tmp.exists("home/Library/Preferences/com.example.game.plist"))
        #expect(tmp.exists("home/Library/Preferences/com.example.gamepad.plist"))
        _ = try store.restore(id: batch.id)
        #expect(tmp.exists("Applications/Game.app/Contents/Info.plist"))
        #expect(tmp.exists("home/Library/Application Support/com.example.game/save.dat"))
    }

    @Test func refusesSystemAppsRunningAppsAndAppleAppsNotFromTheAppStore() throws {
        let tmp = try homeWithLeftovers()
        let home = tmp.url.appendingPathComponent("home")
        let sys = AppInfo(
            url: URL(fileURLWithPath: "/System/Applications/Chess.app"), bundleID: "com.apple.Chess", name: "Chess",
            version: nil, bytes: 1, architectures: [], lastUsed: nil, isApple: true, fromAppStore: false)
        #expect(throws: UninstallError.systemApp) { try AppUninstaller.plan(sys, home: home, runningBundleIDs: []) }

        let safari = AppInfo(
            url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", name: "Safari",
            version: nil, bytes: 1, architectures: [], lastUsed: nil, isApple: true, fromAppStore: false)
        #expect(throws: UninstallError.appleApp) { try AppUninstaller.plan(safari, home: home, runningBundleIDs: []) }

        #expect(throws: UninstallError.running("Game")) {
            try AppUninstaller.plan(game(tmp), home: home, runningBundleIDs: ["com.example.game"])
        }
    }

    @Test func allowsAppleAppStoreAppsLikeGarageBand() throws {
        let tmp = try TempDir()
        try tmp.app("Applications/GarageBand.app", id: "com.apple.garageband10", appStore: true)
        let gb = AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in nil })[0]
        let plan = try AppUninstaller.plan(gb, home: tmp.url.appendingPathComponent("home"), runningBundleIDs: [])
        #expect(plan.paths.first == gb.url)
    }
}

// MARK: - Leftovers of apps that are gone

@Suite("Orphaned leftovers")
struct OrphanTests {
    @Test func findsReverseDNSEntriesThatNoBundleOnDiskOwns() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home")
        try tmp.file("home/Library/Application Support/com.gone.app/data")
        try tmp.file("home/Library/Preferences/com.gone.app.plist")
        try tmp.file("home/Library/HTTPStorages/com.gone.app.binarycookies")
        try tmp.file("home/Library/Application Support/com.example.game.helper/keep")  // owned: installed ID + "."
        try tmp.file("home/Library/Application Support/com.apple.something/keep")  // Apple
        try tmp.file("home/Library/Application Support/SomeFolder/keep")  // not reverse-DNS: can't tell, never listed
        try tmp.file("home/Library/Preferences/com.example.game.plist")
        try tmp.file("home/Library/Application Support/group.com.gone.shared/x")  // app-group ID, not a bundle ID
        try tmp.file("home/Library/Application Support/systemgroup.com.gone.thing/x")
        try FileManager.default.createDirectory(  // takes no space: nothing to gain
            at: home.appendingPathComponent("Library/Application Support/com.empty.app"), withIntermediateDirectories: true)
        let index = BundleIndex(["com.example.game": "Game"])

        let orphans = AppLeftovers.orphans(home: home, bundles: index)
        #expect(orphans.map(\.id) == ["com.gone.app"])
        #expect(orphans[0].paths.count == 3)
        #expect(orphans[0].bytes > 0)
    }
}
