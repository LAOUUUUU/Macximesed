import Foundation
import Testing
@testable import MacxCore

@Suite("Safe cleanup catalogue")
struct CleanupCatalogTests {
    func makeHome() throws -> TempDir {
        let tmp = try TempDir()
        try tmp.file("Library/Caches/com.spotify.client/data.bin", String(repeating: "s", count: 4000))
        try tmp.file("Library/Caches/BraveSoftware/Cache/x", "b")
        try tmp.file("Library/Caches/SomeTool/c", "c")
        try tmp.file("Library/Caches/com.apple.Safari/keep", "apple")
        try tmp.file("Library/Caches/Macximesed/own", "own")
        try tmp.file("Library/Logs/tool.log", "log")
        try tmp.file("Library/Logs/DiagnosticReports/crash.ips", "crash")
        try tmp.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", "dd")
        try tmp.file("Library/Developer/Xcode/iOS DeviceSupport/18.0/x", "ds")
        try tmp.file(".npm/_cacache/index", "npm")
        try tmp.file(".cache/some-venv/bin/python", "venv")
        return tmp
    }

    @Test func listsEachThirdPartyCacheFolderSeparately() throws {
        let home = try makeHome()
        let items = CleanupCatalog.safe(home: home.url, running: [])
        let ids = Set(items.map(\.id))
        #expect(ids.contains("cache:com.spotify.client"))
        #expect(ids.contains("cache:BraveSoftware"))
        #expect(ids.contains("cache:SomeTool"))
        #expect(items.allSatisfy { $0.tier == .safe })
    }

    @Test func neverTouchesAppleCachesOurOwnFolderOrDotCache() throws {
        let home = try makeHome()
        let paths = CleanupCatalog.safe(home: home.url, running: []).flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains("com.apple.") })
        #expect(!paths.contains { $0.hasSuffix("/Macximesed") })
        #expect(!paths.contains { $0.contains("/.cache") })
    }

    @Test func groupsLogsXcodeAndNpm() throws {
        let home = try makeHome()
        let byID = Dictionary(uniqueKeysWithValues: CleanupCatalog.safe(home: home.url, running: []).map { ($0.id, $0) })
        #expect(byID["logs:user"]?.paths.count == 2)
        #expect(byID["xcode:derived-data"]?.paths.map(\.lastPathComponent) == ["App-abc"])
        #expect(byID["xcode:device-support"]?.paths.map(\.lastPathComponent) == ["18.0"])
        #expect(byID["npm:cache"]?.paths.map(\.lastPathComponent) == ["_cacache"])
    }

    @Test func dropsEmptyOrMissingGroups() throws {
        let tmp = try TempDir()
        try FileManager.default.createDirectory(at: tmp.url.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        #expect(CleanupCatalog.safe(home: tmp.url, running: []).isEmpty)
    }

    @Test func measuresSize() throws {
        let home = try makeHome()
        let spotify = CleanupCatalog.safe(home: home.url, running: []).first { $0.id == "cache:com.spotify.client" }
        #expect((spotify?.bytes ?? 0) >= 4000)
    }

    @Test func marksCachesOfRunningAppsAsInUse() throws {
        let home = try makeHome()
        let running = [
            RunningApp(name: "Spotify", bundleID: "com.spotify.client"),
            RunningApp(name: "Brave Browser", bundleID: "com.brave.Browser"),
        ]
        let byID = Dictionary(uniqueKeysWithValues: CleanupCatalog.safe(home: home.url, running: running).map { ($0.id, $0) })
        #expect(byID["cache:com.spotify.client"]?.inUseBy == "Spotify")
        #expect(byID["cache:BraveSoftware"]?.inUseBy == "Brave Browser")
        #expect(byID["cache:SomeTool"]?.inUseBy == nil)
    }

    @Test func appleAppsAndSystemProcessesNeverCountAsOwners() throws {
        let home = try makeHome()
        try home.file("Library/Caches/Docker Desktop/x", "d")
        try home.file("Library/Caches/com.openai.codex/x", "o")
        let running = [
            RunningApp(name: "Dock", bundleID: "com.apple.dock"),
            RunningApp(name: "Open and Save Panel Service (Discord)", bundleID: "com.apple.appkit.xpc.openAndSavePanelService"),
        ]
        let byID = Dictionary(uniqueKeysWithValues: CleanupCatalog.safe(home: home.url, running: running).map { ($0.id, $0) })
        #expect(byID["cache:Docker Desktop"]?.inUseBy == nil)
        #expect(byID["cache:com.openai.codex"]?.inUseBy == nil)
    }

    @Test func skipsAppleFrameworkCachesWithoutTheComApplePrefix() throws {
        let home = try makeHome()
        for name in ["GeoServices", "CloudKit", "PassKit", "Animoji", "GameKit", "FamilyCircle",
                     "softwareupdate", "PFSceneTaxonomyData_99.index", "AMSDataMigratorTool"] {
            try home.file("Library/Caches/\(name)/x", "a")
        }
        let ids = CleanupCatalog.safe(home: home.url, running: []).map(\.id)
        #expect(!ids.contains { $0.contains("GeoServices") || $0.contains("CloudKit") || $0.contains("PassKit")
            || $0.contains("Animoji") || $0.contains("GameKit") || $0.contains("FamilyCircle")
            || $0.contains("softwareupdate") || $0.contains("PFScene") || $0.contains("AMSData") })
    }

    @Test func dropsItemsThatTakeNoSpace() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent("Library/Caches/EmptyApp"), withIntermediateDirectories: true)
        #expect(!CleanupCatalog.safe(home: home.url, running: []).map(\.id).contains("cache:EmptyApp"))
    }

    @Test func selectionHonoursOnlyAndSkipsInUse() throws {
        let home = try makeHome()
        let items = CleanupCatalog.safe(home: home.url, running: [RunningApp(name: "Spotify", bundleID: "com.spotify.client")])
        let all = CleanupCatalog.select(items, only: [], includeInUse: false)
        #expect(!all.map(\.id).contains("cache:com.spotify.client"))
        #expect(all.map(\.id).contains("cache:SomeTool"))

        let one = CleanupCatalog.select(items, only: ["cache:SomeTool"], includeInUse: false)
        #expect(one.map(\.id) == ["cache:SomeTool"])

        let forced = CleanupCatalog.select(items, only: ["cache:com.spotify.client"], includeInUse: true)
        #expect(forced.map(\.id) == ["cache:com.spotify.client"])
    }

    @Test func runningCleanupStashesSelectedItemsSoTheyCanBeRestored() throws {
        let home = try makeHome()
        let store = UndoStore(root: home.url.appendingPathComponent("undo-root"))
        let items = CleanupCatalog.select(CleanupCatalog.safe(home: home.url, running: []), only: ["cache:SomeTool", "npm:cache"], includeInUse: false)
        let batch = try CleanupCatalog.run(items, store: store)
        #expect(!home.exists("Library/Caches/SomeTool"))
        #expect(!home.exists(".npm/_cacache"))
        #expect(home.exists("Library/Caches/com.spotify.client"))
        _ = try store.restore(id: batch.id)
        #expect(home.exists("Library/Caches/SomeTool/c"))
        #expect(home.exists(".npm/_cacache/index"))
    }
}
