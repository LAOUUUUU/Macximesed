import Foundation
import Testing
@testable import MacxCore

@Suite("Bundle index")
struct BundleIndexTests {
    @Test func parsesSpotlightAttributeOutput() {
        let out = """
        /Applications/Docker.app   kMDItemCFBundleIdentifier = com.docker.docker
        /Applications/My Game.app   kMDItemCFBundleIdentifier = com.example.game
        /Applications/Broken.app   kMDItemCFBundleIdentifier = (null)
        garbage line
        """
        let index = BundleIndex.parse(spotlightOutput: out)
        #expect(index.name(of: "com.docker.docker") == "Docker")
        #expect(index.name(of: "com.example.game") == "My Game")
        #expect(index.count == 2)
    }

    @Test func ownerMatchesExactIDOrIDPlusDotAndPicksTheLongest() {
        let index = BundleIndex(["com.example.game": "Game", "com.example.game.pro": "Game Pro", "com.other.app": "Other"])
        #expect(index.owner(of: "com.example.game")?.bundleID == "com.example.game")
        #expect(index.owner(of: "com.example.game.ShipIt")?.bundleID == "com.example.game")
        #expect(index.owner(of: "com.example.game.pro.plist")?.bundleID == "com.example.game.pro")
        #expect(index.owner(of: "com.example.gamepad") == nil)
        #expect(index.owner(of: "Game") == nil) // names are never used
    }
}

@Suite("Reverse-DNS names")
struct ReverseDNSTests {
    @Test func recognisesShapeWithoutAnyTLDList() {
        #expect(ReverseDNS.isReverseDNS("com.example.game"))
        #expect(ReverseDNS.isReverseDNS("io.github.someone.tool"))
        #expect(ReverseDNS.isReverseDNS("xyz.weird-vendor.App_2"))
        #expect(!ReverseDNS.isReverseDNS("com.example"))
        #expect(!ReverseDNS.isReverseDNS("Some Folder"))
        #expect(!ReverseDNS.isReverseDNS("PFSceneTaxonomyData_99.index"))
        #expect(!ReverseDNS.isReverseDNS("Com.Example.Game")) // first part must look like a domain
    }

    @Test func stripsFileTypeExtensions() {
        #expect(ReverseDNS.baseName("com.example.game.plist") == "com.example.game")
        #expect(ReverseDNS.baseName("com.example.game.savedState") == "com.example.game")
        #expect(ReverseDNS.baseName("com.example.game.binarycookies") == "com.example.game")
        #expect(ReverseDNS.baseName("com.example.game") == "com.example.game")
    }
}

@Suite("Safe cleanup catalogue")
struct CleanupCatalogTests {
    func makeHome() throws -> TempDir {
        let tmp = try TempDir()
        try tmp.file("Library/Caches/com.spotify.client/data.bin", String(repeating: "s", count: 4000))
        try tmp.file("Library/Caches/com.spotify.client.installer/x", "i")
        try tmp.file("Library/Caches/com.apple.Safari/keep", "apple")
        try tmp.file("Library/Caches/GeoServices/x", "unknown owner")
        try tmp.file("Library/Caches/BraveSoftware/Cache/x", "unknown owner")
        try tmp.file("Library/Caches/Homebrew/downloads/x", "brew")
        try tmp.file("Library/Caches/Macximesed/own", "own")
        try tmp.file("Library/Caches/com.gone.app/x", "no app")
        try tmp.file("Library/Logs/tool.log", "log")
        try tmp.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", "dd")
        try tmp.file("Elsewhere/DerivedData/Other-xyz/x", "custom dd")
        try tmp.file(".npm/_cacache/index", "npm")
        try tmp.file(".cache/some-venv/bin/python", "venv")
        return tmp
    }

    func context(_ home: TempDir, running: Set<String> = [], open: [OpenFile] = [],
                 derivedData: URL? = nil) -> SystemContext {
        SystemContext(
            home: home.url,
            bundles: BundleIndex(["com.spotify.client": "Spotify", "com.apple.Safari": "Safari"]),
            runningBundleIDs: running,
            openFiles: open,
            toolCaches: [ToolCache(tool: "brew", url: home.url.appendingPathComponent("Library/Caches/Homebrew")),
                         ToolCache(tool: "npm", url: home.url.appendingPathComponent(".npm/_cacache"))],
            derivedData: derivedData
        )
    }

    func byID(_ items: [CleanupItem]) -> [String: CleanupItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    @Test func attributesCachesByExactBundleIDOrTool() throws {
        let home = try makeHome()
        let items = byID(CleanupCatalog.safe(context(home)))
        #expect(items["cache:com.spotify.client"]?.owner == .app(name: "Spotify", bundleID: "com.spotify.client"))
        #expect(items["cache:com.spotify.client.installer"]?.owner == .app(name: "Spotify", bundleID: "com.spotify.client"))
        #expect(items["cache:Homebrew"]?.owner == .tool("brew"))
        #expect(items["npm:cache"]?.owner == .tool("npm"))
        #expect(items["cache:GeoServices"]?.owner == .unknown)
        #expect(items["cache:BraveSoftware"]?.owner == .unknown)
        #expect(items["cache:com.gone.app"]?.owner == .unknown)
    }

    @Test func neverListsAppleCachesOurOwnFolderOrDotCache() throws {
        let home = try makeHome()
        let paths = CleanupCatalog.safe(context(home)).flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains("com.apple.") })
        #expect(!paths.contains { $0.hasSuffix("/Macximesed") })
        #expect(!paths.contains { $0.contains("/.cache") })
    }

    @Test func inUseComesFromOpenFilesAndRunningBundleIDs() throws {
        let home = try makeHome()
        let open = [OpenFile(path: home.url.appendingPathComponent("Library/Caches/BraveSoftware/Cache/x").path, process: "Brave Browser", pid: 42)]
        let items = byID(CleanupCatalog.safe(context(home, running: ["com.spotify.client"], open: open)))
        #expect(items["cache:BraveSoftware"]?.inUseBy == "Brave Browser (pid 42)")
        #expect(items["cache:com.spotify.client"]?.inUseBy == "Spotify")
        #expect(items["cache:GeoServices"]?.inUseBy == nil)
    }

    @Test func defaultSelectionTakesKnownOwnersOnlyAndNothingInUse() throws {
        let home = try makeHome()
        let items = CleanupCatalog.safe(context(home, running: ["com.spotify.client"]))
        let picked = Set(CleanupCatalog.select(items, only: [], includeInUse: false, includeUnknown: false).map(\.id))
        #expect(picked.contains("cache:Homebrew"))
        #expect(picked.contains("logs:user"))
        #expect(!picked.contains("cache:com.spotify.client")) // running
        #expect(!picked.contains("cache:GeoServices")) // unknown owner

        let withUnknown = Set(CleanupCatalog.select(items, only: [], includeInUse: false, includeUnknown: true).map(\.id))
        #expect(withUnknown.contains("cache:GeoServices"))

        // Naming an item with --only is an explicit choice, so unknown owners are allowed.
        let named = CleanupCatalog.select(items, only: ["cache:BraveSoftware"], includeInUse: false, includeUnknown: false)
        #expect(named.map(\.id) == ["cache:BraveSoftware"])
    }

    @Test func usesXcodesCustomDerivedDataLocationWhenSet() throws {
        let home = try makeHome()
        let custom = home.url.appendingPathComponent("Elsewhere/DerivedData")
        let items = byID(CleanupCatalog.safe(context(home, derivedData: custom)))
        #expect(items["xcode:derived-data"]?.paths.map(\.lastPathComponent) == ["Other-xyz"])
        let standard = byID(CleanupCatalog.safe(context(home)))
        #expect(standard["xcode:derived-data"]?.paths.map(\.lastPathComponent) == ["App-abc"])
    }

    @Test func dropsEmptyItems() throws {
        let home = try makeHome()
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent("Library/Caches/EmptyApp"), withIntermediateDirectories: true)
        #expect(!CleanupCatalog.safe(context(home)).map(\.id).contains("cache:EmptyApp"))
    }

    @Test func runningCleanupStashesSelectedItemsSoTheyCanBeRestored() throws {
        let home = try makeHome()
        let store = UndoStore(root: home.url.appendingPathComponent("undo-root"))
        let items = CleanupCatalog.select(CleanupCatalog.safe(context(home)), only: ["cache:Homebrew", "npm:cache"],
                                          includeInUse: false, includeUnknown: false)
        let batch = try CleanupCatalog.run(items, store: store)
        #expect(!home.exists("Library/Caches/Homebrew"))
        #expect(!home.exists(".npm/_cacache"))
        #expect(home.exists("Library/Caches/com.spotify.client"))
        _ = try store.restore(id: batch.id)
        #expect(home.exists("Library/Caches/Homebrew/downloads/x"))
        #expect(home.exists(".npm/_cacache/index"))
    }
}

@Suite("Open files")
struct OpenFilesTests {
    @Test func findsAFileThisProcessHasOpen() throws {
        let tmp = try TempDir()
        let f = try tmp.file("held/open.txt", "x")
        let handle = try FileHandle(forReadingFrom: f)
        defer { try? handle.close() }
        let open = OpenFiles.snapshot()
        #expect(open.contains { $0.path.hasSuffix("held/open.txt") && $0.pid == getpid() })
        #expect(OpenFiles.holder(of: tmp.url.appendingPathComponent("held"), in: open) != nil)
        #expect(OpenFiles.holder(of: tmp.url.appendingPathComponent("hel"), in: open) == nil) // path prefix, not string prefix
    }
}

@Suite("Locale-proof commands")
struct LocaleTests {
    @Test func processRunnerForcesTheCLocale() throws {
        let out = try ProcessRunner().run("/usr/bin/env", [])
        #expect(out.contains("LC_ALL=C"))
        #expect(out.contains("LANG=C"))
    }
}
