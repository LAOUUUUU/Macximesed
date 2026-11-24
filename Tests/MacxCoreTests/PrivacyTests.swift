import Foundation
import Testing

@testable import MacxCore

@Suite("Privacy-protected folders")
struct PrivacyTests {
    let home = URL(fileURLWithPath: "/Users/someone")

    @Test func knowsWhichFoldersMacOSGuards() {
        let p = PrivacyPolicy(home: home, fullDiskAccess: false)
        for path in [
            "/Users/someone/Documents/Builds/Tool.app", "/Users/someone/Desktop/x", "/Users/someone/Downloads/y.dmg",
            "/Users/someone/Library/Containers/com.x.y/Data", "/Users/someone/Library/Group Containers/group.x",
            "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/z", "/Volumes/External/Apps/Editor.app",
            "/Users/someone/Pictures/a", "/Users/someone/Movies/b", "/Users/someone/Music/c",
        ] {
            #expect(!p.allows(URL(fileURLWithPath: path)), "\(path) should be guarded")
        }
        for path in [
            "/Applications/Game.app", "/Users/someone/Library/Caches/x", "/Users/someone/Applications/A.app",
            "/Users/someone/Library/Preferences/x.plist", "/Users/someone/Qt/bin/Designer.app", "/Library/LaunchDaemons/x.plist",
        ] {
            #expect(p.allows(URL(fileURLWithPath: path)), "\(path) should be allowed")
        }
    }

    @Test func fullDiskAccessAllowsEverything() {
        let p = PrivacyPolicy(home: home, fullDiskAccess: true)
        #expect(p.allows(URL(fileURLWithPath: "/Users/someone/Documents/x")))
        #expect(p.allows(URL(fileURLWithPath: "/Users/someone/Library/Containers/x")))
    }

    @Test func doesNotMatchFolderNamePrefixes() {
        let p = PrivacyPolicy(home: home, fullDiskAccess: false)
        #expect(p.allows(URL(fileURLWithPath: "/Users/someone/DocumentsArchive/x")))
        #expect(p.allows(URL(fileURLWithPath: "/Users/someone/Library/ContainersOld/x")))
    }

    @Test func appDiscoverySkipsGuardedPathsAndCountsThem() {
        let out = """
            /Applications/Game.app
            /Users/someone/Documents/Builds/MyTool.app
            /Volumes/External/Apps/Editor.app
            """
        let p = PrivacyPolicy(home: home, fullDiskAccess: false)
        let (kept, skipped) = AppScanner.split(AppScanner.parseAppPaths(out), policy: p)
        #expect(kept.map(\.path) == ["/Applications/Game.app"])
        #expect(skipped == 2)
    }

    @Test func leftoversSkipContainersWithoutFullDiskAccess() throws {
        let tmp = try TempDir()
        try tmp.app("Applications/Game.app", id: "com.example.game", name: "Game")
        try tmp.file("home/Library/Containers/com.example.game/Data/x")
        try tmp.file("home/Library/Caches/com.example.game/c")
        let home = tmp.url.appendingPathComponent("home")
        let game = AppScanner.scan([tmp.url.appendingPathComponent("Applications")], lastUsed: { _ in nil })[0]

        let guarded = AppLeftovers.find(for: game, home: home, policy: PrivacyPolicy(home: home, fullDiskAccess: false))
        #expect(!guarded.contains { $0.path.contains("/Containers/") })
        #expect(guarded.contains { $0.path.contains("/Caches/") })

        let full = AppLeftovers.find(for: game, home: home, policy: PrivacyPolicy(home: home, fullDiskAccess: true))
        #expect(full.contains { $0.path.contains("/Containers/") })
    }

    @Test func signatureOfAGuardedProgramIsNotChecked() {
        let p = PrivacyPolicy(home: home, fullDiskAccess: false)
        let checker = GuardedSignatureChecker(inner: FakeSignatures(byPath: ["/Users/someone/Documents/x/run": .apple]), policy: p)
        #expect(checker.check("/Users/someone/Documents/x/run") == .unreadable)
        #expect(checker.check("/no/such/program") == .missing)  // falls through to the inner checker
    }

    @Test func fullDiskAccessProbeNeverThrows() {
        // On a dev Mac or CI runner this may be either; it must just answer.
        _ = PrivacyPolicy.probeFullDiskAccess()
    }
}

/// macOS 27 removed direct access to TCC.db (and the user copy isn't at the old path), so the old probe said "no"
/// even with Full Disk Access. The probe lists folders that only Full Disk Access opens and that never prompt.
@Suite("Full Disk Access probe (macOS 27)")
struct FullDiskAccessProbeTests {
    @Test func readableProtectedFolderMeansOn() throws {
        let tmp = try TempDir()
        _ = try tmp.file("Library/Safari/Bookmarks.plist", "x")
        #expect(PrivacyPolicy.probeFullDiskAccess(home: tmp.url))
    }

    @Test func refusedProtectedFolderMeansOff() throws {
        let tmp = try TempDir()
        let safari = tmp.url.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: safari.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: safari.path) }
        #expect(!PrivacyPolicy.probeFullDiskAccess(home: tmp.url))
    }

    @Test func missingFoldersAreSkippedNotCountedAsOn() throws {
        let tmp = try TempDir()
        #expect(!PrivacyPolicy.probeFullDiskAccess(home: tmp.url, systemTCC: tmp.url.appendingPathComponent("none")))
        _ = try tmp.file("Library/Mail/V10/x", "x")  // Safari missing, Mail present and readable
        #expect(PrivacyPolicy.probeFullDiskAccess(home: tmp.url))
    }
}
