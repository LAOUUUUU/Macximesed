import Foundation
import Testing

@testable import MacxCore

@Suite("Configuration profiles")
struct ProfileTests {
    /// `profiles show -output stdout-xml` layout: top-level keys are `_computerlevel` or a user name, each an
    /// array of profiles with their payloads in ProfileItems.
    func dump(_ levels: [String: [[String: Any]]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: levels, format: .xml, options: 0)
    }

    func profile(_ id: String, _ name: String, payloads: [[String: Any]], verified: String = "unsigned") -> [String: Any] {
        [
            "ProfileIdentifier": id, "ProfileDisplayName": name, "ProfileUUID": "UUID-\(id)", "ProfileOrganization": "Org",
            "ProfileInstallDate": "2026-11-20 10:00:00 +0000", "ProfileVerificationState": verified, "ProfileType": "Configuration",
            "ProfileItems": payloads,
        ]
    }

    @Test func parsesComputerAndUserLevels() throws {
        let data = try dump([
            "_computerlevel": [profile("com.evil.ca", "Security Update", payloads: [["PayloadType": "com.apple.security.root"]])],
            "lao": [profile("com.example.wifi", "Office Wi-Fi", payloads: [["PayloadType": "com.apple.wifi.managed"]])],
        ])
        let profiles = try ConfigurationProfiles.parse(data)
        #expect(profiles.count == 2)
        let ca = try #require(profiles.first { $0.identifier == "com.evil.ca" })
        #expect(ca.scope == .computer)
        #expect(ca.name == "Security Update")
        #expect(ca.verification == "unsigned")
        #expect(ca.payloadTypes == ["com.apple.security.root"])
        #expect(profiles.first { $0.identifier == "com.example.wifi" }?.scope == .user("lao"))
    }

    @Test func emptyDumpAndJunk() throws {
        #expect(try ConfigurationProfiles.parse(try dump([:])).isEmpty)
        #expect(throws: (any Error).self) { try ConfigurationProfiles.parse(Data("not a plist".utf8)) }
    }

    @Test func capabilitiesFromPayloads() {
        func caps(_ p: [String: Any]) -> Set<ProfileCapability> { ProfileCapability.of(payload: p) }
        #expect(caps(["PayloadType": "com.apple.security.root"]) == [.trustsCertificate])
        #expect(caps(["PayloadType": "com.apple.security.pem"]) == [.trustsCertificate])
        #expect(caps(["PayloadType": "com.apple.proxy.http.global", "ProxyServer": "evil.example"]) == [.proxy])
        #expect(caps(["PayloadType": "com.apple.SystemConfiguration", "Proxies": ["HTTPEnable": 1]]) == [.proxy])
        #expect(caps(["PayloadType": "com.apple.wifi.managed", "ProxyType": "Manual"]) == [.proxy])
        #expect(caps(["PayloadType": "com.apple.wifi.managed"]).isEmpty)
        #expect(caps(["PayloadType": "com.apple.TCC.configuration-profile-policy"]) == [.privacyGrants])
        #expect(caps(["PayloadType": "com.apple.systempolicy.control", "EnableAssessment": false]) == [.gatekeeper])
        #expect(caps(["PayloadType": "com.apple.dnsSettings.managed"]) == [.dns])
        #expect(caps(["PayloadType": "com.apple.vpn.managed"]) == [.vpn])
        #expect(caps(["PayloadType": "com.apple.webcontent-filter"]) == [.contentFilter])
        #expect(caps(["PayloadType": "com.apple.servicemanagement"]) == [.loginItems])
        // Browsers: their own payload type, or the old ManagedClient preferences wrapper.
        #expect(caps(["PayloadType": "com.google.Chrome", "ExtensionInstallForcelist": ["abc;https://x"]]) == [.browserPolicy])
        #expect(
            caps([
                "PayloadType": "com.apple.ManagedClient.preferences",
                "PayloadContent": ["com.google.Chrome": ["Forced": [["mcx_preference_settings": ["HomepageLocation": "https://x"]]]]],
            ]) == [.browserPolicy])
        #expect(
            caps([
                "PayloadType": "com.apple.ManagedClient.preferences",
                "PayloadContent": [
                    "PayloadContentManagedPreferences": ["com.brave.Browser": ["Forced": [["mcx_preference_settings": ["X": true]]]]]
                ],
            ]) == [.browserPolicy])
        #expect(caps(["PayloadType": "com.apple.dock"]).isEmpty)
    }

    func findings(_ p: [String: Any], mdm: Bool) throws -> [Finding] {
        let profiles = try ConfigurationProfiles.parse(try dump(["_computerlevel": [p]]))
        let items = ConfigurationProfiles.items(profiles, managedByMDM: mdm)
        return PersistenceRules.evaluate(items, home: URL(fileURLWithPath: "/Users/v"))
    }

    @Test func handInstalledRootCertificateIsHigh() throws {
        let f = try findings(
            profile("com.evil.ca", "Security Update", payloads: [["PayloadType": "com.apple.security.root"]]), mdm: false)
        let ca = try #require(f.first { $0.rule == "profile-trusts-certificate" })
        #expect(ca.severity == .high)
        #expect(ca.item.kind == .configurationProfile)
        #expect(ca.item.runsAsRoot)
        #expect(f.contains { $0.rule == "profile-installed-by-hand" && $0.severity == .low })
    }

    /// Real `sudo profiles show -output stdout-xml` from macOS 27.0.1 with a hand-installed test profile. Installed,
    /// a custom-settings payload keeps its domains one level down, under PayloadContentManagedPreferences, not in
    /// PayloadContent itself as in the .mobileconfig file.
    @Test func realInstalledProfileWithABrowserPolicyIsHigh() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/profiles-show-installed.xml")
        let profiles = try ConfigurationProfiles.parse(Data(contentsOf: url))
        let p = try #require(profiles.first { $0.identifier == "dev.macximesed.profile-test" })
        #expect(p.scope == .computer)
        #expect(p.capabilities == [.browserPolicy])
        let f = PersistenceRules.evaluate(
            ConfigurationProfiles.items(profiles, managedByMDM: false), home: URL(fileURLWithPath: "/Users/v"))
        #expect(f.contains { $0.rule == "profile-browser-policy" && $0.severity == .high })
    }

    @Test func forcedBrowserExtensionAndProxyAreHigh() throws {
        let f = try findings(
            profile(
                "com.chromeloader", "Chrome",
                payloads: [
                    ["PayloadType": "com.google.Chrome", "ExtensionInstallForcelist": ["abc;https://x"]],
                    ["PayloadType": "com.apple.proxy.http.global"],
                ]), mdm: false)
        #expect(f.contains { $0.rule == "profile-browser-policy" && $0.severity == .high })
        #expect(f.contains { $0.rule == "profile-proxy" && $0.severity == .high })
    }

    @Test func mdmManagedProfilesAreInfoOnly() throws {
        let f = try findings(
            profile("com.corp.ca", "Corp CA", payloads: [["PayloadType": "com.apple.security.root"]], verified: "verified"), mdm: true)
        #expect(f.allSatisfy { $0.severity == .info })
        #expect(f.contains { $0.rule == "profile-managed" })
    }

    @Test func harmlessHandInstalledProfileIsLowOnly() throws {
        let f = try findings(profile("com.me.dock", "Dock", payloads: [["PayloadType": "com.apple.dock"]]), mdm: false)
        #expect(f.map(\.rule) == ["profile-installed-by-hand"])
    }

    @Test func changeInPayloadsChangesTheHash() throws {
        let a = ConfigurationProfiles.items(
            try ConfigurationProfiles.parse(
                try dump(["_computerlevel": [profile("x", "X", payloads: [["PayloadType": "com.apple.dock"]])]])),
            managedByMDM: false)
        let b = ConfigurationProfiles.items(
            try ConfigurationProfiles.parse(
                try dump(["_computerlevel": [profile("x", "X", payloads: [["PayloadType": "com.apple.security.root"]])]])),
            managedByMDM: false)
        #expect(a[0].path == b[0].path)
        #expect(a[0].contentHash != b[0].contentHash)
    }

    @Test func readerUsesAllLevelsOnlyAsRoot() {
        final class Recorder: CommandRunner, @unchecked Sendable {
            var calls: [[String]] = []
            func run(_ executable: String, _ arguments: [String]) throws -> String {
                calls.append([executable] + arguments)
                if arguments.first == "status" { return "Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\n" }
                return #"<?xml version="1.0"?><plist version="1.0"><dict/></plist>"#
            }
        }
        let r = Recorder()
        let user = ConfigurationProfiles.current(runner: r, isRoot: false)
        #expect(r.calls.contains(["/usr/bin/profiles", "show", "-output", "stdout-xml"]))
        #expect(user.note?.contains("sudo") == true)
        #expect(user.managedByMDM)
        r.calls = []
        let root = ConfigurationProfiles.current(runner: r, isRoot: true)
        #expect(r.calls.contains(["/usr/bin/profiles", "show", "-all", "-output", "stdout-xml"]))
        #expect(root.note == nil)
    }
}
