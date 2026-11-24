import Foundation
import Testing

@testable import MacxCore

/// The .pkg's postinstall script (scripts/release/pkg/postinstall), run against a temporary home folder.
@Suite("The .pkg installs into the user's own folders")
struct PackageInstallTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/release/pkg/postinstall")

    func run(staging: URL, home: URL, user: String = "someone") throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [Self.script.path]
        p.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MACX_PKG_STAGING": staging.path, "MACX_PKG_HOME": home.path,
            "MACX_PKG_USER": user, "MACX_PKG_NO_CHOWN": "1", "MACX_PKG_NO_OPEN": "1",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func stage(_ tmp: TempDir, binary: String) throws -> URL {
        let staging = tmp.url.appendingPathComponent("staging")
        let macos = staging.appendingPathComponent("Macximesed.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try Data(binary.utf8).write(to: macos.appendingPathComponent("macx"))
        return staging
    }

    @Test func movesTheAppHomeAndLinksTheCommand() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let staging = try stage(tmp, binary: "new")
        let r = try run(staging: staging, home: home)
        #expect(r.status == 0, "\(r.output)")
        let exe = home.appendingPathComponent("Applications/Macximesed.app/Contents/MacOS/macx")
        #expect(try String(contentsOf: exe, encoding: .utf8) == "new")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".local/bin/macx").path)
        #expect(link == exe.path)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func replacesAnOlderInstall() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home")
        let old = home.appendingPathComponent("Applications/Macximesed.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("macx"))
        try Data("leftover".utf8).write(to: old.appendingPathComponent("stale-file"))
        let r = try run(staging: try stage(tmp, binary: "new"), home: home)
        #expect(r.status == 0, "\(r.output)")
        #expect(try String(contentsOf: old.appendingPathComponent("macx"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("stale-file").path))
    }

    @Test func refusesWhenNobodyIsSignedIn() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for user in ["root", "loginwindow"] {
            let r = try run(staging: try stage(tmp, binary: "new"), home: home, user: user)
            #expect(r.status != 0)
            #expect(r.output.contains("nobody is signed in"))
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications").path))
    }
}
