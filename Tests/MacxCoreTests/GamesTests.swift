import Foundation
import Testing

@testable import MacxCore

@Suite("Games")
struct GamesTests {
    /// A fake .app with an Info.plist and a Mach-O main executable.
    func makeApp(_ tmp: TempDir, _ path: String, id: String, category: String? = nil, gameMode: Bool = false, cpus: [UInt32]) throws {
        var info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleExecutable": "main", "CFBundleName": (path as NSString).lastPathComponent,
        ]
        if let category { info["LSApplicationCategoryType"] = category }
        if gameMode { info["GCSupportsGameMode"] = true }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let app = tmp.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try (cpus.count == 1 ? machO(cpu: cpus[0]) : fatMachO(cpus: cpus)).write(to: app.appendingPathComponent("Contents/MacOS/main"))
    }

    func scan(_ tmp: TempDir, extra: [URL] = []) -> [GameEntry] {
        GameScanner(
            roots: [tmp.url.appendingPathComponent("Applications")], steamApps: tmp.url.appendingPathComponent("Steam/steamapps"),
            bottles: tmp.url.appendingPathComponent("Bottles"), extra: extra, hostIsARM: true
        ).scan()
    }

    @Test func findsGamesByCategoryGameModeAndKnownIDs() throws {
        let tmp = try TempDir()
        try makeApp(
            tmp, "Applications/Balatro.app", id: "com.playstack.balatro", category: "public.app-category.card-games", cpus: [cpuARM64])
        try makeApp(tmp, "Applications/Shooter.app", id: "com.example.shooter", gameMode: true, cpus: [cpuX86_64])
        try makeApp(tmp, "Applications/Roblox.app", id: "com.roblox.RobloxPlayer", cpus: [cpuARM64, cpuX86_64])  // no category
        try makeApp(tmp, "Applications/Notes.app", id: "com.example.notes", category: "public.app-category.productivity", cpus: [cpuARM64])
        let games = scan(tmp)
        #expect(Set(games.map(\.name)) == ["Balatro", "Shooter", "Roblox"])
        let shooter = try #require(games.first { $0.name == "Shooter" })
        #expect(shooter.declaresGameMode)
        #expect(shooter.route == .rosetta)
        #expect(shooter.advice.contains("macOS 27"))
        #expect(try #require(games.first { $0.name == "Balatro" }).route == .native)
        #expect(try #require(games.first { $0.name == "Roblox" }).route == .native)
    }

    @Test func launchersAreMarkedAsLaunchers() throws {
        let tmp = try TempDir()
        try makeApp(tmp, "Applications/Steam.app", id: "com.valvesoftware.steam", cpus: [cpuARM64, cpuX86_64])
        try makeApp(
            tmp, "Applications/GeForceNOW.app", id: "com.nvidia.gfnpc.mall", category: "public.app-category.games", cpus: [cpuARM64])
        let games = scan(tmp)
        #expect(games.first { $0.name == "Steam" }?.kind == .launcher)
        #expect(games.first { $0.name == "GeForceNOW" }?.kind == .launcher)
        #expect(games.first { $0.name == "GeForceNOW" }?.route == .cloud)
    }

    @Test func readsSteamManifests() throws {
        let tmp = try TempDir()
        let acf = """
            "AppState"
            {
            \t"appid"\t\t"646570"
            \t"name"\t\t"Slay the Spire"
            \t"installdir"\t\t"SlayTheSpire"
            }
            """
        _ = try tmp.file("Steam/steamapps/appmanifest_646570.acf", acf)
        try makeApp(tmp, "Steam/steamapps/common/SlayTheSpire/SlayTheSpire.app", id: "com.megacrit.sts", cpus: [cpuX86_64])
        let sts = try #require(scan(tmp).first { $0.name == "Slay the Spire" })
        #expect(sts.kind == .steam(appID: "646570"))
        #expect(sts.route == .rosetta)
        #expect(SteamManifest.parse(acf)?.installDir == "SlayTheSpire")
    }

    @Test func windowsGamesInCrossOverBottles() throws {
        let tmp = try TempDir()
        _ = try tmp.file("Bottles/Games/drive_c/Program Files/Hades/Hades.exe", "MZ")
        _ = try tmp.file("Bottles/Games/drive_c/windows/system32/notepad.exe", "MZ")  // Windows itself: not a game
        let hades = try #require(scan(tmp).first { $0.name == "Hades" })
        #expect(hades.route == .crossover)
        #expect(hades.kind == .windows(bottle: "Games"))
        #expect(!scan(tmp).contains { $0.name == "notepad" })
    }

    @Test func userAddedGamesAreIncluded() throws {
        let tmp = try TempDir()
        try makeApp(tmp, "Elsewhere/Minecraft.app", id: "com.mojang.minecraft", cpus: [cpuARM64])
        let games = scan(tmp, extra: [tmp.url.appendingPathComponent("Elsewhere/Minecraft.app")])
        #expect(games.contains { $0.name == "Minecraft" && $0.kind == .added })
    }

    @Test func sessionSummaryAndSavedLog() {
        var t = HeatTimeline()
        let start = Date(timeIntervalSince1970: 0)
        for i in 0..<30 {
            t.add(.init(time: start.addingTimeInterval(Double(i) * 2), level: i > 20 ? .serious : .fair, pressure: nil, cpuPercent: 150))
        }
        let s = GameSession(game: "Balatro", started: start, ended: start.addingTimeInterval(60), timeline: t, boosted: true)
        let text = s.summary(width: 30)
        #expect(text.contains("Balatro"))
        #expect(text.contains("1 min"))
        #expect(text.contains("Peak: Serious"))
        #expect(text.contains("throttling for 16 s"))
    }

    @Test func aDeadGameSessionMeansBoostMustBeUndone() {
        #expect(GameSessionGuard.needsRestore(gamePID: 123, isAlive: { _ in false }))
        #expect(!GameSessionGuard.needsRestore(gamePID: 123, isAlive: { _ in true }))
    }
}
