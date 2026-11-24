import Foundation
import Testing

@testable import MacxCore

@Suite("Background watch (launchd daemon)")
struct BackgroundWatchTests {
    let app = "/Users/v/Applications/Macximesed.app/Contents/MacOS/macx"
    let user = WatchUser(name: "v", uid: 501, gid: 20, home: URL(fileURLWithPath: "/Users/v"))

    @Test func daemonRunsTheAppsOwnBinaryAsItsOwnResponsibleProcess() throws {
        let plan = try DaemonPlan(executable: URL(fileURLWithPath: app), user: user, suspend: true)
        let p = plan.plist
        #expect(p["Label"] as? String == "dev.macximesed.watch")
        let args = try #require(p["ProgramArguments"] as? [String])
        #expect(args.first == app)
        #expect(Array(args.dropFirst()) == ["watch", "--background", "--suspend"])
        let env = try #require(p["EnvironmentVariables"] as? [String: String])
        // launchd jobs are already their own responsible process: no re-exec, no update check from root.
        #expect(env["MACX_OWN_RESPONSIBILITY"] == "0")
        #expect(env["MACX_NO_UPDATE_CHECK"] == "1")
        #expect(env["MACX_USER"] == "v")
        #expect(p["RunAtLoad"] as? Bool == true)
        // Restart after a crash, not after a clean stop (a refused permission exits cleanly).
        #expect((p["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(p["StandardErrorPath"] as? String == "/Library/Logs/Macximesed/daemon.log")
        #expect(plan.plistPath.path == "/Library/LaunchDaemons/dev.macximesed.watch.plist")
        #expect(try DaemonPlan(executable: URL(fileURLWithPath: app), user: user, suspend: false).arguments == ["watch", "--background"])
    }

    @Test func refusesABinaryOutsideTheApp() {
        // Full Disk Access belongs to Macximesed.app; a bare binary can't hold it on macOS 27.
        #expect(throws: DaemonPlan.Problem.notInApp) {
            try DaemonPlan(executable: URL(fileURLWithPath: "/Users/v/Documents/Macximesed/.build/debug/macx"), user: user, suspend: false)
        }
    }

    @Test func plistIsValidXML() throws {
        let data = try DaemonPlan(executable: URL(fileURLWithPath: app), user: user, suspend: false).plistData()
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(back?["Label"] as? String == "dev.macximesed.watch")
    }

    @Test func watchUserComesFromSudoOrTheDaemonVariable() {
        let lookup: (String) -> WatchUser? = { $0 == "v" ? self.user : nil }
        #expect(WatchUser.resolve(environment: ["SUDO_USER": "v"], lookup: lookup) == user)
        #expect(WatchUser.resolve(environment: ["MACX_USER": "v"], lookup: lookup) == user)
        #expect(WatchUser.resolve(environment: ["MACX_USER": "nobody-here"], lookup: lookup) == nil)
        #expect(WatchUser.resolve(environment: [:], lookup: lookup) == nil)
    }

    @Test func notificationRunsInTheUsersSessionWithEscapedText() {
        let cmd = AlertNotifier.command(
            user: user, title: "Macximesed: CRITICAL", message: #"A "fake" prompt \ by /tmp/x"#)
        #expect(cmd.executable == "/bin/launchctl")
        #expect(Array(cmd.arguments.prefix(5)) == ["asuser", "501", "/usr/bin/sudo", "-u", "v"])
        let script = cmd.arguments.last ?? ""
        #expect(script.contains(#"display notification "A \"fake\" prompt \\ by /tmp/x""#))
        #expect(script.contains(#"with title "Macximesed: CRITICAL""#))
    }

    @Test func statusFileRoundTrips() throws {
        let tmp = try TempDir()
        let f = tmp.url.appendingPathComponent("status.json")
        let s = DaemonStatus(state: .refused, message: "eslogger: needs Full Disk Access", since: Date(timeIntervalSince1970: 1000))
        try s.write(to: f)
        #expect(DaemonStatus.read(from: f) == s)
        #expect(DaemonStatus.read(from: tmp.url.appendingPathComponent("none")) == nil)
    }

    @Test func alertLogLinesAreReadBack() {
        let lines = [
            #"{"detail":"x","epoch":1000,"pid":5,"process":"/tmp/a","rule":"fake-password-prompt","severity":"critical","time":"2026-11-23T10:00:00.000Z","title":"Fake password prompt"}"#,
            "not json",
            #"{"epoch":1001,"frozen":[5],"rule":"frozen","severity":"info","title":"Froze after fake-password-prompt","time":"t"}"#,
        ]
        let records = AlertRecord.parse(lines.joined(separator: "\n"))
        #expect(records.count == 2)
        #expect(records[0].rule == "fake-password-prompt")
        #expect(records[0].severity == .critical)
        #expect(records[0].process == "/tmp/a")
        #expect(records[1].severity == .info)
    }
}

@Suite("Background watch: own daemon and notification grouping")
struct OwnDaemonTests {
    let exe = "/Users/v/Applications/Macximesed.app/Contents/MacOS/macx"

    func daemon(program: String) -> PersistenceItem {
        PersistenceItem(
            kind: .launchDaemon, path: "/Library/LaunchDaemons/dev.macximesed.watch.plist", label: "dev.macximesed.watch",
            program: program, arguments: ["watch", "--background"], runsAsRoot: true, runAtLoad: true, keepAlive: true,
            signature: .adHoc, teamID: nil, contentHash: "x")
    }

    @Test func ownDaemonIsRecognisedOnlyWhenItRunsThisMacx() {
        let home = URL(fileURLWithPath: "/Users/v")
        let ours = PersistenceRules.evaluate([daemon(program: exe)], home: home, ownProgram: exe)
        #expect(ours.map(\.rule) == ["macximesed-background-watch"])
        #expect(ours.first?.severity == .info)
        // Same label, different program: judged like anything else.
        let fake = PersistenceRules.evaluate([daemon(program: "/Users/Shared/.x/macx")], home: home, ownProgram: exe)
        #expect(fake.contains { $0.severity >= .high })
        #expect(!fake.contains { $0.rule == "macximesed-background-watch" })
    }

    @Test func notificationsAreGroupedAndCounted() {
        var t = NotificationThrottle(window: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(t.offer("A", now: t0) == "A")
        #expect(t.offer("B", now: t0.addingTimeInterval(1)) == nil)
        #expect(t.offer("C", now: t0.addingTimeInterval(2)) == nil)
        // After the window, the next one says how many were held back.
        #expect(t.offer("D", now: t0.addingTimeInterval(11)) == "D (and 2 more: macx alerts)")
        #expect(t.offer("E", now: t0.addingTimeInterval(30)) == "E")
    }
}
