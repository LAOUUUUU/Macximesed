import Foundation
import Testing

@testable import MacxCore

/// Plays codesign: each app's designated requirement follows from the identity it was last signed with.
final class FakeSigner: AppSigner, @unchecked Sendable {
    var requirement: [String: String] = [:]
    var available: SigningIdentity?
    var signFlipsIdentity = false  // simulates a re-sign that lands on a different identity
    var signs = 0

    func designatedRequirement(of app: URL) -> String? { requirement[app.path] }
    func preferredIdentity() -> SigningIdentity? { available }
    func sign(_ app: URL, identity: SigningIdentity?, bundleID: String, entitlements: URL) throws {
        signs += 1
        let leaf = signFlipsIdentity && signs == 1 ? "DIFFERENT" : (identity?.hash ?? "")
        requirement[app.path] =
            identity == nil ? "cdhash H\"\(UUID().uuidString)\"" : "identifier \"\(bundleID)\" and certificate leaf = H\"\(leaf)\""
    }
}

@Suite("Updates never cost Full Disk Access")
struct UpdateSafetyTests {
    let stable = SigningIdentity(hash: "6A9E98E2DB2B5769430FC2B14C66198E187A076F", name: "Macximesed Local Signing")

    func makeApp(_ tmp: TempDir) throws -> (app: URL, exe: URL) {
        let app = tmp.url.appendingPathComponent("Macximesed.app")
        let exe = app.appendingPathComponent("Contents/MacOS/macx")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old binary".utf8).write(to: exe)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.macximesed.macx", "CFBundleExecutable": "macx", "CFBundleShortVersionString": "0.2.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return (app, exe)
    }

    func update(_ tmp: TempDir) throws -> Data {
        let pkg = tmp.url.appendingPathComponent("pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: pkg.appendingPathComponent("macx").path)
        let tgz = tmp.url.appendingPathComponent("\(UUID().uuidString).tar.gz")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-czf", tgz.path, "-C", pkg.path, "macx"])
        return try Data(contentsOf: tgz)
    }

    func installer(_ signer: FakeSigner, root: Bool = false, previous: URL) -> UpdateInstaller {
        UpdateInstaller(versionOf: { _ in "0.3.0" }, signer: signer, isRoot: root, previousFolder: previous)
    }

    @Test func neverInstallsAsRoot() throws {
        let tmp = try TempDir()
        let (_, exe) = try makeApp(tmp)
        let data = try update(tmp)
        let signer = FakeSigner()
        #expect(throws: UpdateError.needsUser) {
            try installer(signer, root: true, previous: tmp.url).install(
                data, sha256: sha256(data), version: "0.3.0", over: exe, installed: SemVer("0.2.0")!)
        }
        #expect(try String(contentsOf: exe, encoding: .utf8) == "old binary")
    }

    @Test func keepsTheOldVersionWhenTheSigningIdentityIsMissing() throws {
        let tmp = try TempDir()
        let (app, exe) = try makeApp(tmp)
        let data = try update(tmp)
        let signer = FakeSigner()
        signer.requirement[app.path] = "identifier \"dev.macximesed.macx\" and certificate leaf = H\"\(stable.hash)\""
        signer.available = nil
        #expect(throws: UpdateError.signingIdentityMissing) {
            try installer(signer, previous: tmp.url).install(
                data, sha256: sha256(data), version: "0.3.0", over: exe, installed: SemVer("0.2.0")!)
        }
        #expect(try String(contentsOf: exe, encoding: .utf8) == "old binary")
        #expect(signer.signs == 0)
    }

    @Test func rollsBackWhenTheIdentityChangesAfterSigning() throws {
        let tmp = try TempDir()
        let (app, exe) = try makeApp(tmp)
        let data = try update(tmp)
        let signer = FakeSigner()
        let before = "identifier \"dev.macximesed.macx\" and certificate leaf = H\"\(stable.hash)\""
        signer.requirement[app.path] = before
        signer.available = stable
        signer.signFlipsIdentity = true
        #expect(throws: UpdateError.identityChanged) {
            try installer(signer, previous: tmp.url).install(
                data, sha256: sha256(data), version: "0.3.0", over: exe, installed: SemVer("0.2.0")!)
        }
        #expect(try String(contentsOf: exe, encoding: .utf8) == "old binary")
        #expect(signer.requirement[app.path] == before)  // re-signed back to what macOS knows
    }

    @Test func updatesWhenTheIdentityStaysTheSame() throws {
        let tmp = try TempDir()
        let (app, exe) = try makeApp(tmp)
        let data = try update(tmp)
        let signer = FakeSigner()
        let before = "identifier \"dev.macximesed.macx\" and certificate leaf = H\"\(stable.hash)\""
        signer.requirement[app.path] = before
        signer.available = stable
        try installer(signer, previous: tmp.url).install(
            data, sha256: sha256(data), version: "0.3.0", over: exe, installed: SemVer("0.2.0")!)
        #expect(try Data(contentsOf: exe) == Data(contentsOf: URL(fileURLWithPath: "/bin/cat")))
        #expect(signer.requirement[app.path] == before)
    }

    @Test func anAdHocAppHasNothingToLoseAndStillUpdates() throws {
        let tmp = try TempDir()
        let (app, exe) = try makeApp(tmp)
        let data = try update(tmp)
        let signer = FakeSigner()
        signer.requirement[app.path] = "cdhash H\"0123\""
        signer.available = nil
        try installer(signer, previous: tmp.url).install(
            data, sha256: sha256(data), version: "0.3.0", over: exe, installed: SemVer("0.2.0")!)
        #expect(try Data(contentsOf: exe) == Data(contentsOf: URL(fileURLWithPath: "/bin/cat")))
    }

    @Test func stableRequirementsAreRecognised() {
        #expect(UpdateInstaller.isStable("identifier \"x\" and certificate leaf = H\"ab\""))
        #expect(
            UpdateInstaller.isStable(
                "identifier \"x\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: a\""))
        #expect(!UpdateInstaller.isStable("cdhash H\"0123\""))
        #expect(!UpdateInstaller.isStable(nil))
    }
}

@Suite("Background watch picks up updates")
struct BinaryStampTests {
    @Test func noticesWhenItsBinaryIsReplaced() throws {
        let tmp = try TempDir()
        let f = try tmp.file("macx", "v1")
        let stamp = try #require(BinaryStamp(of: f))
        #expect(!stamp.changed())
        let staged = try tmp.file("macx.new", "v2 longer")
        #expect(rename(staged.path, f.path) == 0)  // how the updater swaps it: a new file over the old name
        #expect(stamp.changed())
    }
}

/// With the real codesign and the real local identity, on a copy of the installed app. Opt-in: needs the identity
/// in the login keychain (MACX_SIGNING_INTEGRATION=1).
@Suite("Update keeps the real app's identity", .enabled(if: ProcessInfo.processInfo.environment["MACX_SIGNING_INTEGRATION"] == "1"))
struct RealSigningUpdateTests {
    @Test func updatingACopyOfTheInstalledAppKeepsItsRequirement() throws {
        let tmp = try TempDir()
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Macximesed.app")
        let app = tmp.url.appendingPathComponent("Macximesed.app")
        _ = try ProcessRunner().run("/usr/bin/ditto", [installed.path, app.path])
        let signer = RealAppSigner()
        let before = try #require(signer.designatedRequirement(of: app))
        #expect(UpdateInstaller.isStable(before))

        let pkg = tmp.url.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: pkg.appendingPathComponent("macx").path)
        let tgz = tmp.url.appendingPathComponent("u.tar.gz")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-czf", tgz.path, "-C", pkg.path, "macx"])
        let data = try Data(contentsOf: tgz)

        try UpdateInstaller(versionOf: { _ in "9.9.9" }, signer: signer, isRoot: false, previousFolder: tmp.url).install(
            data, sha256: sha256(data), version: "9.9.9", over: app.appendingPathComponent("Contents/MacOS/macx"),
            installed: SemVer("0.2.0")!)
        #expect(signer.designatedRequirement(of: app) == before)
        #expect(ProcessRunner.capture("/usr/bin/codesign", ["--verify", "--strict", app.path])?.status == 0)
        let ent = ProcessRunner.capture("/usr/bin/codesign", ["-d", "--entitlements", "-", app.path])
        let entText = (ent?.stdout ?? "") + (ent?.stderr ?? "")
        #expect(entText.contains("com.apple.security.virtualization"))
    }
}
