import Foundation
import Testing

@testable import MacxCore

/// Plays codesign for whole-app updates: an app's requirement and signer come from marker files inside it, so an
/// app that was just unpacked somewhere new still carries its (fake) signature.
final class MarkerSigner: AppSigner, @unchecked Sendable {
    var signs = 0
    func designatedRequirement(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/fake-requirement"), encoding: .utf8)
    }
    func preferredIdentity() -> SigningIdentity? { nil }
    func sign(_ app: URL, identity: SigningIdentity?, bundleID: String, entitlements: URL) throws { signs += 1 }
    func verifies(_ app: URL) -> Bool {
        !FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/fake-broken").path)
    }
    func authority(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/fake-authority"), encoding: .utf8)
    }
}

@Suite("Whole-app updates (release-signed installs)")
struct WholeAppUpdateTests {
    static let release = "identifier \"dev.macximesed.macx\" and certificate leaf = H\"aaaa\""

    /// A Macximesed.app in `dir`, signed (by marker) with `requirement`.
    @discardableResult
    func makeApp(
        in dir: URL, binary: String? = nil, requirement: String = release, broken: Bool = false,
        authority: String = UpdateMethod.releaseAuthority
    ) throws -> URL {
        let app = dir.appendingPathComponent("Macximesed.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        if let binary {
            try Data(binary.utf8).write(to: macos.appendingPathComponent("macx"))
        } else {
            try FileManager.default.copyItem(atPath: "/bin/cat", toPath: macos.appendingPathComponent("macx").path)
        }
        try Data(requirement.utf8).write(to: app.appendingPathComponent("Contents/fake-requirement"))
        try Data(authority.utf8).write(to: app.appendingPathComponent("Contents/fake-authority"))
        if broken { try Data().write(to: app.appendingPathComponent("Contents/fake-broken")) }
        return app
    }

    /// The release's app archive: `Macximesed.app` at the top, as CI makes it.
    func archive(_ tmp: TempDir, _ build: (URL) throws -> Void = { _ in }) throws -> Data {
        let src = tmp.url.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeApp(in: src)
        try build(src)
        let tgz = tmp.url.appendingPathComponent("\(UUID().uuidString).tar.gz")
        let names = try FileManager.default.contentsOfDirectory(atPath: src.path).sorted()
        _ = try ProcessRunner().run("/usr/bin/tar", ["-czf", tgz.path, "-C", src.path] + names)
        return try Data(contentsOf: tgz)
    }

    func installed(_ tmp: TempDir) throws -> URL {
        let dir = tmp.url.appendingPathComponent("Applications")
        return try makeApp(in: dir, binary: "old binary")
    }

    func installer(_ signer: MarkerSigner, tmp: TempDir, root: Bool = false, reports: String = "0.4.0") -> UpdateInstaller {
        UpdateInstaller(
            versionOf: { _ in reports }, signer: signer, isRoot: root, previousFolder: tmp.url.appendingPathComponent("support"))
    }

    func oldBinary(_ app: URL) throws -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/macx"), encoding: .utf8)
    }

    @Test func swapsInTheWholeSignedApp() throws {
        let tmp = try TempDir()
        let app = try installed(tmp)
        let data = try archive(tmp)
        try installer(MarkerSigner(), tmp: tmp).installApp(
            data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        let now = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/macx"))
        #expect(now == (try Data(contentsOf: URL(fileURLWithPath: "/bin/cat"))))
        let previous = tmp.url.appendingPathComponent("support/Macximesed.app.previous")
        #expect(try oldBinary(previous) == "old binary")
        // Nothing left behind next to the app.
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["Macximesed.app"])
    }

    @Test func refusesAnAppSignedByAnyoneElse() throws {
        let tmp = try TempDir()
        let app = try installed(tmp)
        let data = try archive(tmp) { src in
            try Data("identifier \"dev.macximesed.macx\" and certificate leaf = H\"bbbb\"".utf8)
                .write(to: src.appendingPathComponent("Macximesed.app/Contents/fake-requirement"))
        }
        #expect(throws: UpdateError.identityChanged) {
            try installer(MarkerSigner(), tmp: tmp).installApp(
                data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(try oldBinary(app) == "old binary")
    }

    @Test func refusesWhenTheInstalledAppIsAdHoc() throws {
        let tmp = try TempDir()
        let dir = tmp.url.appendingPathComponent("Applications")
        let app = try makeApp(in: dir, binary: "old binary", requirement: "cdhash H\"1234\"")
        let data = try archive(tmp) { src in
            try Data("cdhash H\"1234\"".utf8).write(to: src.appendingPathComponent("Macximesed.app/Contents/fake-requirement"))
        }
        #expect(throws: UpdateError.identityChanged) {
            try installer(MarkerSigner(), tmp: tmp).installApp(
                data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(try oldBinary(app) == "old binary")
    }

    @Test func refusesABrokenSignature() throws {
        let tmp = try TempDir()
        let app = try installed(tmp)
        let data = try archive(tmp) { src in
            try Data().write(to: src.appendingPathComponent("Macximesed.app/Contents/fake-broken"))
        }
        #expect(throws: UpdateError.appSignatureInvalid) {
            try installer(MarkerSigner(), tmp: tmp).installApp(
                data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(try oldBinary(app) == "old binary")
    }

    @Test func refusesLinksAndExtraTopLevelItems() throws {
        let tmp = try TempDir()
        let app = try installed(tmp)
        let linked = try archive(tmp) { src in
            try FileManager.default.createSymbolicLink(
                atPath: src.appendingPathComponent("Macximesed.app/Contents/Resources").path, withDestinationPath: "/etc")
        }
        let extra = try archive(tmp) { src in try Data("x".utf8).write(to: src.appendingPathComponent("evil.sh")) }
        for data in [linked, extra] {
            #expect(throws: UpdateError.notAProgram) {
                try installer(MarkerSigner(), tmp: tmp).installApp(
                    data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
            }
        }
        #expect(try oldBinary(app) == "old binary")
    }

    @Test func theUsualChecksStillApply() throws {
        let tmp = try TempDir()
        let app = try installed(tmp)
        let data = try archive(tmp)
        #expect(throws: UpdateError.needsUser) {
            try installer(MarkerSigner(), tmp: tmp, root: true).installApp(
                data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(throws: UpdateError.hashMismatch) {
            try installer(MarkerSigner(), tmp: tmp).installApp(
                data, sha256: String(repeating: "0", count: 64), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(throws: UpdateError.notNewer) {
            try installer(MarkerSigner(), tmp: tmp).installApp(
                data, sha256: sha256(data), version: "0.3.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(throws: UpdateError.versionMismatch) {
            try installer(MarkerSigner(), tmp: tmp, reports: "0.3.9").installApp(
                data, sha256: sha256(data), version: "0.4.0", over: app, installed: SemVer("0.3.0")!)
        }
        #expect(try oldBinary(app) == "old binary")
    }

    @Test func releaseSignedAppsTakeTheWholeAppOthersTheBinary() {
        let app = URL(fileURLWithPath: "/Users/v/Applications/Macximesed.app")
        #expect(UpdateMethod.choose(app: app, authority: UpdateMethod.releaseAuthority, hasAppAsset: true) == .wholeApp)
        #expect(UpdateMethod.choose(app: app, authority: UpdateMethod.releaseAuthority, hasAppAsset: false) == .binary)
        #expect(UpdateMethod.choose(app: app, authority: "Macximesed Local Signing", hasAppAsset: true) == .binary)
        #expect(UpdateMethod.choose(app: nil, authority: nil, hasAppAsset: true) == .binary)
    }

    @Test func channelCarriesTheAppArchiveAndOldFilesStillRead() throws {
        let with = #"""
            {"schema":1,"sequence":5,"published":"2026-11-24T00:00:00Z","expires":"2027-02-22T00:00:00Z",
             "latest":{"version":"0.4.0","url":"https://x/macx.tar.gz","sha256":"aa",
                       "app":{"url":"https://x/Macximesed-0.4.0-app.tar.gz","sha256":"bb"}}}
            """#
        let without = #"""
            {"schema":1,"sequence":5,"published":"2026-11-24T00:00:00Z","expires":"2027-02-22T00:00:00Z",
             "latest":{"version":"0.4.0","url":"https://x/macx.tar.gz","sha256":"aa"}}
            """#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(UpdateChannel.self, from: Data(with.utf8)).latest.app?.sha256 == "bb")
        #expect(try d.decode(UpdateChannel.self, from: Data(without.utf8)).latest.app == nil)
    }
}

/// The whole-app update with the real codesign: throwaway "Macximesed Release Signing" certificates in temporary
/// keychains, apps built by scripts/make-app.sh, as the release workflow does (MACX_RELEASE_SIGNING_INTEGRATION=1).
@Suite(
    "Whole-app update with real signatures",
    .enabled(if: ProcessInfo.processInfo.environment["MACX_RELEASE_SIGNING_INTEGRATION"] == "1"))
struct RealWholeAppUpdateTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// A temporary keychain holding a fresh self-signed release certificate. Returns the keychain path.
    func makeCertificate(_ tmp: TempDir, _ name: String) throws -> String {
        let script = #"""
            set -eu
            cd "$1"
            printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Macximesed Release Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > c.cnf
            /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config c.cnf -keyout k.pem -out c.pem 2>/dev/null
            /usr/bin/openssl pkcs12 -export -inkey k.pem -in c.pem -name x -out r.p12 -passout pass:pw
            security create-keychain -p kc "$2" >/dev/null
            security unlock-keychain -p kc "$2"
            security import r.p12 -k "$2" -P pw -T /usr/bin/codesign >/dev/null
            security set-key-partition-list -S apple-tool:,apple: -s -k kc "$2" >/dev/null 2>&1
            """#
        let dir = tmp.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = dir.appendingPathComponent("r.keychain-db").path
        _ = try ProcessRunner(timeout: 60).run("/bin/sh", ["-c", script, "sh", dir.path, keychain])
        return keychain
    }

    func build(_ tmp: TempDir, _ dir: String, keychain: String) throws -> URL {
        let app = tmp.url.appendingPathComponent("\(dir)/Macximesed.app")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try ProcessRunner(timeout: 60).run(
            Self.root.appendingPathComponent("scripts/make-app.sh").path,
            ["/bin/cat", app.path, "0.4.0", "Macximesed Release Signing", keychain])
        return app
    }

    func archive(_ app: URL, _ tmp: TempDir) throws -> Data {
        let tgz = tmp.url.appendingPathComponent("\(UUID().uuidString).tar.gz")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-czf", tgz.path, "-C", app.deletingLastPathComponent().path, "Macximesed.app"])
        return try Data(contentsOf: tgz)
    }

    @Test func swapsInTheNewAppAndRefusesAnotherCertificate() throws {
        let tmp = try TempDir()
        let ours = try makeCertificate(tmp, "ours")
        let theirs = try makeCertificate(tmp, "theirs")
        defer { for k in [ours, theirs] { _ = try? ProcessRunner().run("/usr/bin/security", ["delete-keychain", k]) } }
        let signer = RealAppSigner()
        let installed = try build(tmp, "Applications", keychain: ours)
        #expect(signer.authority(of: installed) == UpdateMethod.releaseAuthority)
        let before = try #require(signer.designatedRequirement(of: installed))
        #expect(UpdateInstaller.isStable(before))
        let installer = UpdateInstaller(
            versionOf: { _ in "0.4.0" }, signer: signer, isRoot: false, previousFolder: tmp.url.appendingPathComponent("support"))

        let forged = try archive(try build(tmp, "forged", keychain: theirs), tmp)
        #expect(throws: UpdateError.identityChanged) {
            try installer.installApp(forged, sha256: sha256(forged), version: "0.4.0", over: installed, installed: SemVer("0.3.0")!)
        }

        let real = try archive(try build(tmp, "release", keychain: ours), tmp)
        try installer.installApp(real, sha256: sha256(real), version: "0.4.0", over: installed, installed: SemVer("0.3.0")!)
        #expect(signer.designatedRequirement(of: installed) == before)
        #expect(signer.verifies(installed))
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("support/Macximesed.app.previous").path))
    }
}
