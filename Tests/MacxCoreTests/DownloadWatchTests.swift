import Foundation
import Testing

@testable import MacxCore

@Suite("Downloads watch: spotting a finished download")
struct DownloadDetectionTests {
    let downloads = "/Users/v/Downloads"

    func rename(_ from: String, _ to: String) -> ESEvent {
        let dir = (to as NSString).deletingLastPathComponent
        let name = (to as NSString).lastPathComponent
        let body =
            #"{"source":{"path":"\#(from)"},"destination_type":1,"destination":{"new_path":{"dir":{"path":"\#(dir)"},"filename":"\#(name)"}}}"#
        return ESEvent.parse(
            event("rename", process: proc("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", pid: 70), body: body))!
    }

    func create(_ path: String) -> ESEvent {
        ESEvent.parse(event("create", process: proc("/usr/bin/curl", pid: 71, platform: true), body: createBody(path)))!
    }

    @Test(arguments: [
        ("/Users/v/Downloads/Setup.dmg.crdownload", "/Users/v/Downloads/Setup.dmg"),  // Chrome
        ("/Users/v/Downloads/Setup.dmg.part", "/Users/v/Downloads/Setup.dmg"),  // Firefox
        ("/Users/v/Downloads/Setup.dmg.download/Setup.dmg", "/Users/v/Downloads/Setup.dmg"),  // Safari: out of its .download folder
        ("/Users/v/Downloads/Unconfirmed 123456.crdownload", "/Users/v/Downloads/Installer.pkg"),
    ])
    func browserRenamesAreFinishedDownloads(_ from: String, _ to: String) {
        #expect(DownloadWatch.finishedDownload(rename(from, to), downloads: downloads) == to)
    }

    @Test func savedStraightIntoDownloadsCounts() {
        #expect(DownloadWatch.finishedDownload(create("/Users/v/Downloads/run.sh"), downloads: downloads) == "/Users/v/Downloads/run.sh")
    }

    @Test(arguments: [
        "/Users/v/Downloads/Setup.dmg.crdownload",  // still downloading
        "/Users/v/Downloads/Setup.dmg.part",
        "/Users/v/Downloads/Setup.dmg.download",  // Safari's in-progress folder (or a stuck one)
        "/Users/v/Downloads/.DS_Store",
        "/Users/v/Downloads/._Setup.dmg",
        "/Users/v/Downloads/sub/Setup.dmg",  // inside a subfolder: an unpacked archive, not a download
        "/Users/v/Documents/Setup.dmg",
    ])
    func othersAreNot(_ path: String) {
        #expect(DownloadWatch.finishedDownload(create(path), downloads: downloads) == nil)
    }

    @Test func renamesWithinDownloadsThatAreNotBrowserFinishesAreSkipped() {
        // The user renaming a file they already have isn't a new download.
        #expect(DownloadWatch.finishedDownload(rename("/Users/v/Downloads/a.pdf", "/Users/v/Downloads/b.pdf"), downloads: downloads) == nil)
        // A file moved in from elsewhere is new to Downloads, so it's checked.
        #expect(
            DownloadWatch.finishedDownload(rename("/Users/v/Desktop/a.pkg", "/Users/v/Downloads/a.pkg"), downloads: downloads)
                == "/Users/v/Downloads/a.pkg")
    }
}

@Suite("Downloads watch: verdicts, quarantine, restoring")
struct DownloadVerdictTests {
    func report(_ path: URL, _ findings: [CheckFinding], inner: [FileReport] = []) -> FileReport {
        var r = FileReport(path: path, kind: .script)
        r.findings = findings
        r.inner = inner
        return r
    }

    @Test func verdictsBecomeAlerts() {
        let f = URL(fileURLWithPath: "/Users/v/Downloads/x.sh")
        let bad = DownloadWatch.alert(
            for: report(f, [CheckFinding(rule: "base64-to-shell", severity: .critical, title: "Decodes hidden code and runs it")]))
        #expect(bad.rule == "download-dangerous")
        #expect(bad.severity == .critical)
        #expect(bad.title.contains("x.sh"))
        #expect((bad.detail ?? "").contains("Decodes hidden code"))
        let careful = DownloadWatch.alert(for: report(f, [CheckFinding(rule: "unsigned", severity: .medium, title: "Not signed")]))
        #expect(careful.rule == "download-caution")
        #expect(careful.severity == .medium)
        #expect(DownloadWatch.alert(for: report(f, [])).severity == .info)
    }

    @Test func aBadFileInsideADiskImageCounts() {
        let dmg = URL(fileURLWithPath: "/Users/v/Downloads/App.dmg")
        let inner = report(
            URL(fileURLWithPath: "/Volumes/App/run.sh"),
            [CheckFinding(rule: "download-to-shell", severity: .critical, title: "Downloads code and runs it")])
        #expect(DownloadWatch.alert(for: report(dmg, [], inner: [inner])).rule == "download-dangerous")
    }

    @Test func quarantineMovesItIntoACaseAndTheUndoStoreAndRestoringAllowsIt() throws {
        let tmp = try TempDir()
        let home = tmp.url.appendingPathComponent("home")
        let file = try tmp.file("home/Downloads/Invoice.pkg", "evil")
        let r = report(file, [CheckFinding(rule: "known-malware", severity: .critical, title: "Known malware")])
        let q = try DownloadWatch.quarantine(file, report: r, home: home, owner: nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(q.caseID.contains("download-dangerous"))

        // Restoring it means the user decided it's fine: that exact file is allowed from now on.
        let store = UndoStore(root: home.appendingPathComponent("Library/Application Support/Macximesed/Undo"))
        let batch = try #require(try store.batches().first { $0.id == q.batchID })
        _ = try store.restore(id: q.batchID)
        DownloadWatch.allowRestored(batch, home: home)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(DownloadWatch.isAllowed(sha256(Data("evil".utf8)), home: home))
        #expect(!DownloadWatch.isAllowed(sha256(Data("other".utf8)), home: home))
    }
}

@Suite("Downloads watch: daemon setting")
struct DownloadDaemonTests {
    @Test func onByDefaultAndCanBeTurnedOff() throws {
        let user = WatchUser(name: "v", uid: 501, gid: 20, home: URL(fileURLWithPath: "/Users/v"))
        let exe = URL(fileURLWithPath: "/Users/v/Applications/Macximesed.app/Contents/MacOS/macx")
        #expect(!(try DaemonPlan(executable: exe, user: user, suspend: true).arguments.contains("--no-downloads")))
        #expect(try DaemonPlan(executable: exe, user: user, suspend: true, downloads: false).arguments.contains("--no-downloads"))
    }

    let user = WatchUser(name: "v", uid: 501, gid: 20, home: URL(fileURLWithPath: "/Users/v"))
    let exe = URL(fileURLWithPath: "/Users/v/Applications/Macximesed.app/Contents/MacOS/macx")

    /// The setting is read from the root-owned launchd plist the daemon was installed with: anyone can read it.
    @Test func settingsAreReadFromTheInstalledPlist() throws {
        let on = DaemonSettings(plist: try DaemonPlan(executable: exe, user: user, suspend: true).plist)
        #expect(on == DaemonSettings(suspend: true, downloads: true))
        let off = DaemonSettings(plist: try DaemonPlan(executable: exe, user: user, suspend: false, downloads: false).plist)
        #expect(off == DaemonSettings(suspend: false, downloads: false))
        #expect(DaemonSettings(plist: ["Label": "com.example.other", "ProgramArguments": ["/bin/sh"]]) == nil)
        #expect(DaemonSettings(plist: ["Label": DaemonPlan.label]) == nil)
    }

    @Test func settingsAreReadFromAFile() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("watch.plist")
        try DaemonPlan(executable: exe, user: user, suspend: false, downloads: false).plistData().write(to: file)
        #expect(DaemonSettings.read(from: file)?.downloads == false)
        #expect(DaemonSettings.read(from: tmp.url.appendingPathComponent("missing.plist")) == nil)
    }

    /// `sudo macx daemon downloads on|off` rewrites only the Downloads switch: freezing, the program, the user and
    /// every other key stay as installed.
    @Test func switchingDownloadsKeepsEverythingElse() throws {
        let installed = try DaemonPlan(executable: exe, user: user, suspend: true).plist
        let off = try #require(DaemonSettings.plist(installed, downloads: false))
        #expect(off["ProgramArguments"] as? [String] == [exe.path, "watch", "--background", "--suspend", "--no-downloads"])
        #expect(DaemonSettings(plist: off) == DaemonSettings(suspend: true, downloads: false))
        #expect((off["EnvironmentVariables"] as? [String: String])?["MACX_USER"] == "v")
        #expect(Set(off.keys) == Set(installed.keys))

        let again = try #require(DaemonSettings.plist(off, downloads: false))
        #expect((again["ProgramArguments"] as? [String])?.filter { $0 == "--no-downloads" }.count == 1)

        let on = try #require(DaemonSettings.plist(off, downloads: true))
        #expect(on["ProgramArguments"] as? [String] == [exe.path, "watch", "--background", "--suspend"])
        #expect(DaemonSettings.plist(["Label": "com.example.other"], downloads: false) == nil)
    }

    /// The app's Freeze switch reinstalls the daemon; that must not turn a switched-off Downloads watch back on.
    @Test func reinstallingForFreezingKeepsTheDownloadsSetting() {
        let off = DaemonSettings(suspend: true, downloads: false)
        #expect(DaemonSettings.installArguments(suspend: false, keeping: off) == ["daemon", "install", "--no-downloads"])
        #expect(
            DaemonSettings.installArguments(suspend: true, keeping: DaemonSettings(suspend: false, downloads: true)) == [
                "daemon", "install", "--suspend",
            ])
        #expect(DaemonSettings.installArguments(suspend: true, keeping: nil) == ["daemon", "install", "--suspend"])  // a first install
    }
}
