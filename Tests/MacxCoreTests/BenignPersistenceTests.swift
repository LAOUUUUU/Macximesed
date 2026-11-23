import Foundation
import Testing

@testable import MacxCore

/// False-positive suite for `macx persist`: launch items shaped like the ones common, legitimate software
/// installs (written for this test, not copied), each with the kind of signature that software really has.
/// None may come out high or critical. Medium findings are allowed but counted, and the expected ones are
/// listed so a change in behaviour shows up.
@Suite("Benign persistence (false positives)")
struct BenignPersistenceTests {
    struct Case {
        var name: String
        var kind: PersistenceKind
        var plist: [String: Any]
        var signature: SignatureInfo
    }

    let cases: [Case] = [
        Case(
            name: "Docker privileged helper", kind: .launchDaemon,
            plist: ["Label": "com.docker.vmnetd", "Program": "/Library/PrivilegedHelperTools/com.docker.vmnetd", "RunAtLoad": true],
            signature: .developerID(team: "9BNSXJN65R")),
        Case(
            name: "Google updater agent", kind: .userLaunchAgent,
            plist: [
                "Label": "com.google.keystone.agent",
                "ProgramArguments": [
                    "/Users/v/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent",
                    "-runMode", "ifneeded",
                ],
                "StartInterval": 3523,
            ],
            signature: .developerID(team: "EQHXZ8M8AV")),
        Case(
            name: "Microsoft AutoUpdate", kind: .launchAgent,
            plist: [
                "Label": "com.microsoft.update.agent",
                "ProgramArguments": [
                    "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/Microsoft Update Assistant.app/Contents/MacOS/Microsoft Update Assistant",
                    "--launchByAgent",
                ],
            ],
            signature: .developerID(team: "UBF8T346G9")),
        Case(
            name: "Zoom daemon", kind: .launchDaemon,
            plist: ["Label": "us.zoom.ZoomDaemon", "Program": "/Library/PrivilegedHelperTools/us.zoom.ZoomDaemon", "KeepAlive": true],
            signature: .developerID(team: "BJ4HAAB9B3")),
        Case(
            name: "JetBrains Toolbox", kind: .userLaunchAgent,
            plist: [
                "Label": "com.jetbrains.toolbox",
                "ProgramArguments": ["/Applications/JetBrains Toolbox.app/Contents/MacOS/jetbrains-toolbox", "--minimize"],
                "RunAtLoad": true,
            ],
            signature: .developerID(team: "2ZEFAR8TH3")),
        Case(
            name: "Steam cleanup agent", kind: .userLaunchAgent,
            plist: ["Label": "com.valvesoftware.steamclean", "Program": "/Users/v/Library/Application Support/Steam/SteamApps/steamclean"],
            signature: .developerID(team: "MXGJJ98X76")),
        Case(
            name: "Wireshark ChmodBPF", kind: .launchDaemon,
            plist: [
                "Label": "org.wireshark.ChmodBPF", "ProgramArguments": ["/Library/Application Support/Wireshark/ChmodBPF/ChmodBPF"],
                "RunAtLoad": true,
            ],
            signature: .developerID(team: "7Z6EMTD2C6")),
        Case(
            name: "App opened at login with /usr/bin/open", kind: .userLaunchAgent,
            plist: [
                "Label": "com.vendor.autolaunch", "ProgramArguments": ["/usr/bin/open", "-a", "/Applications/Vendor.app"],
                "RunAtLoad": true,
            ],
            signature: .apple),
        Case(
            name: "Homebrew service (brew services)", kind: .userLaunchAgent,
            plist: [
                "Label": "homebrew.mxcl.postgresql@16",
                "ProgramArguments": ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"],
                "RunAtLoad": true, "KeepAlive": true,
            ],
            signature: .adHoc),  // Homebrew bottles are ad-hoc signed
        Case(
            name: "Tailscale-style login item helper", kind: .userLaunchAgent,
            plist: [
                "Label": "io.tailscale.ipn.macsys.login-item-helper",
                "Program":
                    "/Applications/Tailscale.app/Contents/Library/LoginItems/IPNLoginItemHelper.app/Contents/MacOS/IPNLoginItemHelper",
            ],
            signature: .developerID(team: "W5364U7YZB")),
    ]

    func evaluate() throws -> [String: [Finding]] {
        let tmp = try TempDir()
        var out: [String: [Finding]] = [:]
        for (i, c) in cases.enumerated() {
            let f = try tmp.plist("p\(i)/\(c.plist["Label"] as! String).plist", c.plist)
            let program = (c.plist["Program"] as? String) ?? (c.plist["ProgramArguments"] as? [String])?.first ?? ""
            let item = try #require(LaunchdParser.parse(f, kind: c.kind, signatures: FakeSignatures(byPath: [program: c.signature])))
            out[c.name] = PersistenceRules.evaluate([item], home: URL(fileURLWithPath: "/Users/v"))
        }
        return out
    }

    @Test func noLegitimateItemIsHighOrCritical() throws {
        for (name, findings) in try evaluate() {
            #expect(!findings.contains { $0.severity >= .high }, "\(name): \(findings.map(\.rule))")
        }
    }

    @Test func knownMediumsAreOnlyTheExpectedOnes() throws {
        let mediums = try evaluate().filter { !$0.value.isEmpty }.mapValues { $0.map(\.rule).sorted() }
        // Homebrew's ad-hoc signed bottles are a known medium; everything else must be clean.
        #expect(mediums == ["Homebrew service (brew services)": ["adhoc-program"]])
    }
}
