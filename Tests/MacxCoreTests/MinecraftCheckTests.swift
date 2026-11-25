import Foundation
import SQLite3
import Testing

@testable import MacxCore

@Suite("Minecraft check")
struct MinecraftCheckTests {
    let gb: UInt64 = 1 << 30

    func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func write(_ s: String, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }

    func mods(_ names: [String], in dir: URL) {
        for n in names { write("", dir.appendingPathComponent(n)) }
    }

    @Test func prismInstancesReadTheirOwnSettingsOrTheGlobalOnes() {
        let root = temp()
        write("JavaPath=/global/java\nMaxMemAlloc=6000\n", root.appendingPathComponent("prismlauncher.cfg"))
        let a = root.appendingPathComponent("instances/1.21.11")
        write(
            "name=1.21.11\nOverrideMemory=true\nMaxMemAlloc=6912\nOverrideJavaLocation=true\nJavaPath=/own/java\n",
            a.appendingPathComponent("instance.cfg"))
        write(#"{"components":[{"uid":"net.minecraft"},{"uid":"net.fabricmc.fabric-loader"}]}"#, a.appendingPathComponent("mmc-pack.json"))
        mods(["sodium-fabric-0.6.jar", "lithium-fabric-0.15.jar"], in: a.appendingPathComponent("minecraft/mods"))
        let b = root.appendingPathComponent("instances/26.2")
        write("name=26.2\n", b.appendingPathComponent("instance.cfg"))
        mods(["appleskin.jar"], in: b.appendingPathComponent(".minecraft/mods"))
        write("", root.appendingPathComponent("instances/instgroups.json"))

        let found = MinecraftCheck.prismInstances(root: root).sorted { $0.name < $1.name }
        #expect(found.map(\.name) == ["1.21.11", "26.2"])
        #expect(found[0].memoryMB == 6912 && found[0].javaPath == "/own/java" && found[0].loader == .fabric)
        #expect(found[0].mods.count == 2)
        #expect(found[1].memoryMB == 6000 && found[1].javaPath == "/global/java" && found[1].mods == ["appleskin.jar"])
        #expect(found.allSatisfy { $0.launcher == "Prism" })
    }

    @Test func modrinthProfilesUseTheAppMemoryAndModsFolder() throws {
        let root = temp()
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("app.db").path, &db) == SQLITE_OK)
        sqlite3_exec(db, "create table settings (mc_memory_max integer); insert into settings values (4096);", nil, nil, nil)
        sqlite3_close(db)
        mods(["fabric-api.jar", "sodium.jar", "ferritecore.jar"], in: root.appendingPathComponent("profiles/Fabric 26.3/mods"))
        let found = MinecraftCheck.modrinthInstances(root: root)
        #expect(found.count == 1)
        #expect(found.first?.name == "Fabric 26.3" && found.first?.memoryMB == 4096 && found.first?.launcher == "Modrinth")
        #expect(found.first?.loader == .fabric)  // guessed from fabric-api
    }

    @Test func adviceNamesMissingSpeedModsByLoader() {
        let fabric = MinecraftInstance(
            launcher: "Prism", name: "x", javaPath: nil, memoryMB: 4096, mods: ["sodium-fabric.jar"], loader: .fabric)
        let notes = MinecraftCheck.advice(fabric, physicalBytes: 16 * gb, javaArchs: [])
        #expect(notes.contains { $0.contains("Lithium") })
        #expect(notes.contains { $0.contains("FerriteCore") })
        #expect(!notes.contains { $0.contains("Sodium") })
        // Forge ports count: Embeddium is Sodium for Forge.
        let forge = MinecraftInstance(
            launcher: "Prism", name: "y", javaPath: nil, memoryMB: 4096, mods: ["embeddium-1.0.jar", "canary.jar", "ferritecore.jar"],
            loader: .forge)
        #expect(MinecraftCheck.advice(forge, physicalBytes: 16 * gb, javaArchs: ["arm64"]).isEmpty)
        // Vanilla (no loader, no mods): nothing about mods.
        let vanilla = MinecraftInstance(launcher: "Prism", name: "z", javaPath: nil, memoryMB: 2048, mods: [], loader: nil)
        #expect(MinecraftCheck.advice(vanilla, physicalBytes: 16 * gb, javaArchs: ["arm64"]).isEmpty)
    }

    @Test func theLoaderIsTheMajorityAndForgeGetsForgeMods() {
        let mods = ["a-forge.jar", "b-forge.jar", "c_FORGE.jar", "dh-fabric-forge.jar", "embeddium-0.3.jar", "ferritecore-forge.jar"]
        #expect(MinecraftCheck.loader(fromMods: mods) == .forge)
        let forge = MinecraftInstance(launcher: "Modrinth", name: "x", javaPath: nil, memoryMB: 6144, mods: mods, loader: .forge)
        let notes = MinecraftCheck.advice(forge, physicalBytes: 16 * gb, javaArchs: [])
        #expect(notes == ["No Canary (game logic): https://modrinth.com/mod/canary"])
    }

    @Test func adviceOnMemoryAndJava() {
        let big = MinecraftInstance(launcher: "Prism", name: "x", javaPath: "/j", memoryMB: 10240, mods: [], loader: nil)
        #expect(MinecraftCheck.advice(big, physicalBytes: 16 * gb, javaArchs: ["arm64"]).contains { $0.contains("10 GB") })
        let heavy = MinecraftInstance(
            launcher: "Prism", name: "x", javaPath: "/j", memoryMB: 2048, mods: (0..<150).map { "m\($0).jar" }, loader: .fabric)
        #expect(MinecraftCheck.advice(heavy, physicalBytes: 16 * gb, javaArchs: ["arm64"]).contains { $0.contains("150 mods") })
        let intel = MinecraftInstance(launcher: "Prism", name: "x", javaPath: "/j", memoryMB: 4096, mods: [], loader: nil)
        #expect(MinecraftCheck.advice(intel, physicalBytes: 16 * gb, javaArchs: ["x86_64"]).contains { $0.contains("Rosetta") })
    }

    @Test func machOArchitectures() {
        #expect(MinecraftCheck.archs(of: "/bin/ls").contains("arm64"))
        #expect(MinecraftCheck.archs(of: "/nonexistent").isEmpty)
    }
}
