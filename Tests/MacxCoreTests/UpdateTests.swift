import CryptoKit
import Foundation
import Testing

@testable import MacxCore

// MARK: - Helpers

struct TestSigner {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: Data { key.publicKey.rawRepresentation }

    func sign(_ channel: UpdateChannel) throws -> (Data, Data) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let json = try enc.encode(channel)
        return (json, try key.signature(for: json))
    }
}

func channel(sequence: Int = 5, latest: String = "0.3.0", minimumSafe: String? = nil, expires: Date = Date().addingTimeInterval(14 * 86400))
    -> UpdateChannel
{
    UpdateChannel(
        schema: 1, sequence: sequence, published: Date(), expires: expires,
        latest: .init(version: latest, url: "https://github.com/x/y/releases/download/v\(latest)/macx.tar.gz", sha256: "abc", notes: nil),
        minimumSafe: minimumSafe.map { .init(version: $0, reason: "a security bug", advisory: nil) })
}

// MARK: - Versions

@Suite("Versions")
struct SemVerTests {
    @Test func comparesNumerically() throws {
        #expect(try #require(SemVer("0.10.0")) > #require(SemVer("0.9.9")))
        #expect(try #require(SemVer("1.0.0")) > #require(SemVer("0.99.99")))
        #expect(try #require(SemVer("0.2.0")) == #require(SemVer("0.2.0")))
        #expect(try #require(SemVer("v0.2.0")) == #require(SemVer("0.2.0")))
    }

    @Test func preReleasesSortBeforeTheRelease() throws {
        #expect(try #require(SemVer("1.0.0-beta.2")) < #require(SemVer("1.0.0")))
        #expect(try #require(SemVer("1.0.0-beta.2")) > #require(SemVer("1.0.0-beta.1")))
    }

    @Test func rejectsJunk() {
        #expect(SemVer("") == nil)
        #expect(SemVer("one.two") == nil)
        #expect(SemVer("1.2") == nil)
    }
}

// MARK: - Signature

@Suite("Channel signature")
struct ChannelSignatureTests {
    @Test func verifiesWithTheRightKey() throws {
        let s = TestSigner()
        let (json, sig) = try s.sign(channel())
        let c = try ChannelVerifier(publicKeys: [s.publicKey]).verify(json: json, signature: sig)
        #expect(c.sequence == 5)
        #expect(c.latest.version == "0.3.0")
    }

    @Test func rejectsAChangedFileAWrongKeyAndJunk() throws {
        let s = TestSigner()
        var (json, sig) = try s.sign(channel())
        let v = ChannelVerifier(publicKeys: [s.publicKey])
        json[json.count / 2] ^= 0x01
        #expect(throws: UpdateError.badSignature) { try v.verify(json: json, signature: sig) }

        (json, sig) = try s.sign(channel())
        #expect(throws: UpdateError.badSignature) {
            try ChannelVerifier(publicKeys: [TestSigner().publicKey]).verify(json: json, signature: sig)
        }
        #expect(throws: UpdateError.badSignature) { try v.verify(json: json, signature: Data()) }
    }

    @Test func anyListedKeyWorksForRotation() throws {
        let old = TestSigner()
        let new = TestSigner()
        let (json, sig) = try new.sign(channel())
        _ = try ChannelVerifier(publicKeys: [old.publicKey, new.publicKey]).verify(json: json, signature: sig)
    }

    @Test func theBuiltInKeyIsValid() throws {
        #expect(UpdateKeys.trusted.count >= 1)
        for k in UpdateKeys.trusted { _ = try Curve25519.Signing.PublicKey(rawRepresentation: k) }
    }
}

// MARK: - Decisions

@Suite("Update decisions")
struct UpdateDecisionTests {
    let installed = SemVer("0.2.0")!

    @Test func upToDate() {
        let d = UpdateDecision.decide(channel(latest: "0.2.0"), installed: installed, state: UpdateState(), now: Date())
        #expect(d.action == .none)
    }

    @Test func newerVersionIsOnlyANotice() {
        let d = UpdateDecision.decide(channel(latest: "0.3.0"), installed: installed, state: UpdateState(), now: Date())
        #expect(d.action == .notify("0.3.0"))
    }

    @Test func belowTheSecurityFloorIsForced() {
        let d = UpdateDecision.decide(
            channel(latest: "0.3.0", minimumSafe: "0.2.1"), installed: installed, state: UpdateState(), now: Date())
        #expect(d.action == .force("0.3.0", reason: "a security bug"))
    }

    @Test func atTheFloorIsNotForced() {
        let d = UpdateDecision.decide(
            channel(latest: "0.3.0", minimumSafe: "0.2.0"), installed: installed, state: UpdateState(), now: Date())
        #expect(d.action == .notify("0.3.0"))
    }

    @Test func rollbackIsRejected() {
        let d = UpdateDecision.decide(channel(sequence: 3), installed: installed, state: UpdateState(lastSequence: 4), now: Date())
        #expect(d.action == .none)
        #expect(d.warnings.contains { $0.contains("older") })
    }

    @Test func staleChannelWarnsAndNeverForces() {
        let d = UpdateDecision.decide(
            channel(latest: "0.3.0", minimumSafe: "0.2.1", expires: Date().addingTimeInterval(-86400)), installed: installed,
            state: UpdateState(), now: Date())
        #expect(d.action == .notify("0.3.0"))
        #expect(d.warnings.contains { $0.contains("out of date") })
    }

    @Test func neverOffersAnOlderVersion() {
        let d = UpdateDecision.decide(channel(latest: "0.1.0"), installed: installed, state: UpdateState(), now: Date())
        #expect(d.action == .none)
    }

    @Test func checksAtMostOncePerDay() {
        let now = Date()
        #expect(UpdateState().isCheckDue(now: now))
        #expect(!UpdateState(lastCheck: now.addingTimeInterval(-3600)).isCheckDue(now: now))
        #expect(UpdateState(lastCheck: now.addingTimeInterval(-25 * 3600)).isCheckDue(now: now))
    }

    @Test func stateSurvivesSaveAndLoad() throws {
        let tmp = try TempDir()
        let f = tmp.url.appendingPathComponent("state.json")
        let s = UpdateState(lastCheck: Date(timeIntervalSince1970: 1_800_000_000), lastSequence: 9, noticesOff: true)
        try s.save(to: f)
        #expect(UpdateState.load(from: f) == s)
        #expect(UpdateState.load(from: tmp.url.appendingPathComponent("missing")) == UpdateState())
    }
}

// MARK: - Installing

@Suite("Installing an update")
struct UpdateInstallTests {
    func tarball(_ tmp: TempDir, name: String = "macx", from source: String = "/bin/ls") throws -> Data {
        let dir = tmp.url.appendingPathComponent("pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source, toPath: dir.appendingPathComponent(name).path)
        let tgz = tmp.url.appendingPathComponent("\(UUID().uuidString).tar.gz")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-czf", tgz.path, "-C", dir.path, name])
        return try Data(contentsOf: tgz)
    }

    func installer(reports version: String?) -> UpdateInstaller {
        UpdateInstaller(versionOf: { _ in version })
    }

    @Test func installsAtomicallyAndKeepsThePrevious() throws {
        let tmp = try TempDir()
        let target = try tmp.file("bin/macx", "old binary")
        let data = try tarball(tmp)
        try installer(reports: "0.3.0").install(data, sha256: sha256(data), version: "0.3.0", over: target, installed: SemVer("0.2.0")!)
        #expect(try Data(contentsOf: target) == Data(contentsOf: URL(fileURLWithPath: "/bin/ls")))
        #expect(try tmp.read("bin/macx.previous") == "old binary")
        #expect(FileManager.default.isExecutableFile(atPath: target.path))
    }

    @Test func refusesAWrongHash() throws {
        let tmp = try TempDir()
        let target = try tmp.file("bin/macx", "old binary")
        let data = try tarball(tmp)
        #expect(throws: UpdateError.hashMismatch) {
            try installer(reports: "0.3.0").install(
                data, sha256: String(repeating: "0", count: 64), version: "0.3.0", over: target,
                installed: SemVer("0.2.0")!)
        }
        #expect(try tmp.read("bin/macx") == "old binary")
    }

    @Test func refusesSomethingThatIsntAProgramNamedMacx() throws {
        let tmp = try TempDir()
        let target = try tmp.file("bin/macx", "old binary")
        let script = try tmp.file("fake.sh", "#!/bin/sh\necho hi\n")
        let notMachO = try tarball(tmp, from: script.path)
        #expect(throws: UpdateError.notAProgram) {
            try installer(reports: "0.3.0").install(
                notMachO, sha256: sha256(notMachO), version: "0.3.0", over: target, installed: SemVer("0.2.0")!)
        }
        let wrongName = try tarball(tmp, name: "other")
        #expect(throws: UpdateError.notAProgram) {
            try installer(reports: "0.3.0").install(
                wrongName, sha256: sha256(wrongName), version: "0.3.0", over: target, installed: SemVer("0.2.0")!)
        }
        #expect(try tmp.read("bin/macx") == "old binary")
    }

    @Test func refusesWhenTheNewBinarySaysADifferentVersionOrAnOlderOne() throws {
        let tmp = try TempDir()
        let target = try tmp.file("bin/macx", "old binary")
        let data = try tarball(tmp)
        #expect(throws: UpdateError.versionMismatch) {
            try installer(reports: "0.2.5").install(data, sha256: sha256(data), version: "0.3.0", over: target, installed: SemVer("0.2.0")!)
        }
        #expect(throws: UpdateError.notNewer) {
            try installer(reports: "0.1.0").install(data, sha256: sha256(data), version: "0.1.0", over: target, installed: SemVer("0.2.0")!)
        }
        #expect(try tmp.read("bin/macx") == "old binary")
    }
}

@Suite("Channel file format")
struct ChannelFormatTests {
    @Test func readsWhatTheReleaseScriptWrites() throws {
        // Byte-for-byte what scripts/release/make-channel.py writes (sorted keys, compact, whole-second UTC dates).
        let json = Data(
            #"{"expires":"2027-02-21T20:20:00Z","latest":{"sha256":"abc","url":"https://github.com/LAOUUUUU/Macximesed/releases/download/v0.2.0/macx-v0.2.0-macos-universal.tar.gz","version":"0.2.0"},"minimumSafe":{"reason":"test floor","version":"0.2.0"},"published":"2026-11-23T20:20:00Z","schema":1,"sequence":2}"#
                .utf8)
        let s = TestSigner()
        let c = try ChannelVerifier(publicKeys: [s.publicKey]).verify(json: json, signature: try s.key.signature(for: json))
        #expect(c.sequence == 2)
        #expect(c.minimumSafe?.reason == "test floor")
        #expect(c.latest.notes == nil)
        #expect(c.expires > c.published)
    }
}

@Suite("Updating inside the app bundle")
struct AppBundleUpdateTests {
    @Test func swapInsideAnAppKeepsTheBundleSignatureValidAndVersionCurrent() throws {
        let tmp = try TempDir()
        // A minimal Macximesed.app around a real Mach-O, ad-hoc signed like scripts/install.sh does.
        let app = tmp.url.appendingPathComponent("Macximesed.app")
        let exe = app.appendingPathComponent("Contents/MacOS/macx")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: exe.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.macximesed.macx", "CFBundleExecutable": "macx", "CFBundleName": "Macximesed",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.2.0", "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try ProcessRunner().run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "dev.macximesed.macx", app.path])

        // The update tarball: a different real Mach-O.
        let pkg = tmp.url.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: pkg.appendingPathComponent("macx").path)
        let tgz = tmp.url.appendingPathComponent("u.tar.gz")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-czf", tgz.path, "-C", pkg.path, "macx"])
        let data = try Data(contentsOf: tgz)

        try UpdateInstaller(versionOf: { _ in "0.3.0" }).install(
            data, sha256: sha256(data), version: "0.3.0", over: exe, installed: SemVer("0.2.0")!)

        // Re-signing rewrites the signature inside the binary, so compare what it is, not its bytes.
        #expect(try Data(contentsOf: exe) != Data(contentsOf: URL(fileURLWithPath: "/bin/ls")))
        #expect(!MachO.architectures(ofFile: exe).isEmpty)
        let verify = ProcessRunner.capture("/usr/bin/codesign", ["--verify", "--strict", app.path])
        #expect(verify?.status == 0, "\(verify?.stderr ?? "")")
        let plist =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(plist?["CFBundleShortVersionString"] as? String == "0.3.0")
        // The previous binary is kept outside the bundle, so it doesn't break the seal.
        #expect(!FileManager.default.fileExists(atPath: exe.deletingLastPathComponent().appendingPathComponent("macx.previous").path))
    }
}

@Suite("Signing identity")
struct SigningIdentityTests {
    let sample = """
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Someone Else (ZZZZZZZZZZ)"
          2) A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 "Apple Development: someone@example.com (ABCDE12345)"
          3) FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "Apple Development: other@example.com (QWERTY1234)" (CSSMERR_TP_CERT_EXPIRED)
             3 valid identities found
        """

    @Test func prefersTheFirstValidAppleDevelopmentIdentity() {
        let id = SigningIdentity.parse(findIdentityOutput: sample)
        #expect(id?.hash == "A1B2C3D4E5F60718293A4B5C6D7E8F9012345678")
        #expect(id?.name == "Apple Development: someone@example.com (ABCDE12345)")
    }

    @Test func noneMeansAdHoc() {
        #expect(SigningIdentity.parse(findIdentityOutput: "     0 valid identities found\n") == nil)
        #expect(SigningIdentity.codesignArgument(nil) == "-")
        #expect(SigningIdentity.codesignArgument(SigningIdentity(hash: "AB", name: "x")) == "AB")
    }
}
