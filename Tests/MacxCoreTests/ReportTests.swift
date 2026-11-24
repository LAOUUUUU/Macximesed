import Foundation
import Testing

@testable import MacxCore

@Suite("Bug report: redaction")
struct ReportRedactionTests {
    let redactor = ReportRedactor(homes: ["/Users/jsmith"], names: ["jsmith", "Jane Smith"], hosts: ["Janes-MacBook-Air"])

    @Test func personalDetailsAreRemoved() {
        let text = """
            2026-11-24T10:00:00Z INFO cli[42] downloads: /Users/jsmith/Documents/Tax 2026 - J Smith.pdf → dangerous
            checked /Users/other/Desktop/x.sh for jsmith on Janes-MacBook-Air, mail jane@example.com
            connect 203.0.113.7:443 and [2001:db8::1]:443, loopback 127.0.0.1, wifi aa:bb:cc:dd:ee:ff
            sha 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef by /Applications/Secret Tool.app/Contents/MacOS/x
            Jane Smith wrote ~/Library/LaunchAgents/com.example.agent.plist at 10:00:00
            """
        let (out, count) = redactor.redact(text)
        #expect(out.contains("downloads: ~/Documents/….pdf → dangerous"))
        #expect(out.contains("checked /Users/<user>/Desktop/x.sh for <user> on <host>, mail <email>"))
        #expect(out.contains("connect <ip>:443 and [<ip>]:443, loopback 127.0.0.1, wifi <mac>"))
        #expect(out.contains("sha <sha256> by /Applications/<app>.app/Contents/MacOS/x"))
        // macx's own Library paths matter for bugs (launch items), and times aren't addresses.
        #expect(out.contains("<user> wrote ~/Library/LaunchAgents/com.example.agent.plist at 10:00:00"))
        for leak in ["jsmith", "Jane", "Smith", "Tax 2026", "Janes-MacBook", "example.com", "203.0.113", "Secret Tool", "2001:db8"] {
            #expect(!out.contains(leak), "\(leak) leaked")
        }
        #expect(count >= 12)
    }

    @Test func fileAndProgramNamesCanBeKeptOnPurpose() {
        var r = redactor
        r.keepFileNames = true
        r.keepProgramNames = true
        let (out, _) = r.redact("/Users/jsmith/Downloads/setup.dmg by /Applications/Secret Tool.app")
        #expect(out == "~/Downloads/setup.dmg by /Applications/Secret Tool.app")
    }

    /// A home inside a longer path is not that home: `/private/tmp/h` isn't `/tmp/h` with a prefix.
    @Test func homeOnlyMatchesAtTheStartOfAPath() {
        let r = ReportRedactor(homes: ["/tmp/h"], names: [], hosts: [])
        #expect(r.redact("/private/tmp/h/Downloads/a.pdf").0 == "/private/tmp/h/Downloads/a.pdf")
        let both = ReportRedactor(homes: ["/tmp/h", "/private/tmp/h"], names: [], hosts: [])
        #expect(both.redact("/private/tmp/h/Downloads/a.pdf and /tmp/h/x").0 == "~/Downloads/….pdf and ~/x")
        let line = LogLine.format(
            time: Date(), level: .info, role: .cli, pid: 1, category: "c", message: "/private/tmp/h/x", homes: ["/tmp/h"])
        #expect(line.contains("/private/tmp/h/x"))
    }

    @Test func emptySectionsSaySo() {
        let input = BugReportInput(description: "", facts: [], crashes: [], queuedCrashes: [], alerts: [], logs: [])
        let (text, _) = BugReport.build(input, redactor: redactor, created: Date())
        #expect(text.contains("## Recent alerts (0)\nNone.\n"))
        #expect(text.contains("## Logs\nNone found.\n"))
    }

    @Test func macximesedItselfIsNeverHidden() {
        let (out, _) = redactor.redact("/Applications/Macximesed.app and /Users/jsmith/Applications/Macximesed.app")
        #expect(out == "/Applications/Macximesed.app and ~/Applications/Macximesed.app")
    }
}

@Suite("Bug report: crash summaries")
struct CrashSummaryTests {
    static func ips(name: String = "macx", bugType: String = "309") -> String {
        let header =
            #"{"app_name":"\#(name)","timestamp":"2026-11-24 12:34:56.00 -0500","name":"\#(name)","bug_type":"\#(bugType)","os_version":"macOS 27.0.1 (25A354)","incident_id":"ABC"}"#
        let body = #"""
            {"procPath":"/Users/jsmith/Applications/Macximesed.app/Contents/MacOS/macx","crashReporterKey":"SECRET-DEVICE-ID","pid":4242,"uptime":9999,
             "cpuType":"ARM-64","translated":false,"osVersion":{"train":"macOS 27.0.1","build":"25A354"},
             "bundleInfo":{"CFBundleShortVersionString":"0.3.0"},
             "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010"},
             "termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},
             "faultingThread":1,
             "usedImages":[{"name":"macx","uuid":"11111111-2222-3333-4444-555555555555","path":"/Users/jsmith/x/macx"},{"name":"libsystem_kernel.dylib","uuid":"AA"}],
             "threads":[{"frames":[{"imageIndex":1,"imageOffset":10}]},
                        {"triggered":true,"frames":[{"imageIndex":0,"imageOffset":4096,"symbol":"MacxCore.Watch.run()","symbolLocation":12},
                                                    {"imageIndex":1,"imageOffset":77}]}]}
            """#
        return header + "\n" + body
    }

    @Test func keepsTheCrashAndDropsTheDevice() throws {
        let s = try #require(CrashSummary.parse(ips: Self.ips()))
        #expect(s.process == "macx" && s.version == "0.3.0")
        #expect(s.exception == "EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0000000000000010")
        #expect(s.termination == "Segmentation fault: 11")
        #expect(s.frames == ["macx  MacxCore.Watch.run() + 12", "libsystem_kernel.dylib  + 77"])
        #expect(s.os == "macOS 27.0.1 (25A354)" && s.cpu == "ARM-64")
        #expect(s.imageUUID == "11111111-2222-3333-4444-555555555555")
        for leak in ["SECRET-DEVICE-ID", "jsmith", "4242", "9999", "ABC"] {
            #expect(!s.text.contains(leak), "\(leak) leaked")
        }
    }

    @Test func otherProgramsAndOtherKindsAreIgnored() {
        #expect(CrashSummary.parse(ips: Self.ips(name: "Safari")) == nil)
        #expect(CrashSummary.parse(ips: Self.ips(bugType: "288")) == nil)  // a hang report, not a crash
        #expect(CrashSummary.parse(ips: "not json") == nil)
    }

    @Test func findsOnlyNewMacxCrashFiles() throws {
        let tmp = try TempDir()
        let old = try tmp.file("macx-2026-11-20-100000.ips", Self.ips())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: old.path)
        try tmp.file("macx-2026-11-24-123456.ips", Self.ips())
        try tmp.file("Safari-2026-11-24-123456.ips", Self.ips(name: "Safari"))
        try tmp.file("macx-notes.txt", "x")
        let found = CrashReports.find(in: tmp.url, since: Date(timeIntervalSince1970: 2000))
        #expect(found.map(\.lastPathComponent) == ["macx-2026-11-24-123456.ips"])
    }

    /// The root daemon can't ask anyone, so it leaves redacted summaries where the app and `macx report` can read
    /// them (root-owned in real use).
    @Test func daemonCrashesWaitInAQueue() throws {
        let tmp = try TempDir()
        let queue = CrashQueue(folder: tmp.url.appendingPathComponent("crashes"))
        let s = try #require(CrashSummary.parse(ips: Self.ips()))
        try queue.add([s], role: "background watch")
        let waiting = queue.waiting()
        #expect(waiting.count == 1)
        #expect(waiting.first?.contains("EXC_BAD_ACCESS") == true && waiting.first?.contains("background watch") == true)
    }
}

@Suite("Bug report: the report")
struct BugReportTests {
    let redactor = ReportRedactor(homes: ["/Users/jsmith"], names: ["jsmith"], hosts: [])

    func alert(_ rule: String, process: String, detail: String) -> AlertRecord {
        AlertRecord(
            time: Date(timeIntervalSince1970: 1_795_514_400), rule: rule, severity: .high, title: "t", detail: detail, process: process)
    }

    @Test func alertsCarryOnlyRuleSeverityAndTime() {
        let input = BugReportInput(
            description: "It froze my editor",
            facts: [("macx", "0.3.0")],
            crashes: [],
            queuedCrashes: [],
            alerts: [
                alert("download-to-shell", process: "/bin/zsh", detail: "secret command"),
                alert("x", process: "/Applications/A.app/a", detail: ""),
            ],
            logs: [])
        let (text, _) = BugReport.build(input, redactor: redactor, created: Date(timeIntervalSince1970: 1_795_514_400))
        #expect(text.hasPrefix("Macximesed bug report (format 1)\nCreated: 2026-11-24 10:00 UTC\n"))
        #expect(text.contains("It froze my editor"))
        #expect(text.contains("macx: 0.3.0"))
        #expect(text.contains("2026-11-24 10:00  high  download-to-shell  (part of macOS)"))
        #expect(text.contains("2026-11-24 10:00  high  x  (another program)"))
        #expect(!text.contains("secret command") && !text.contains("A.app"))
    }

    @Test func logsAreRedactedAndTheCountIsShown() {
        let input = BugReportInput(
            description: "", facts: [], crashes: [], queuedCrashes: [], alerts: [],
            logs: [("cli.log", ["a line about /Users/jsmith/Desktop/plan.txt by jsmith"])])
        let (text, count) = BugReport.build(input, redactor: redactor, created: Date())
        #expect(text.contains("### cli.log"))
        #expect(text.contains("a line about ~/Desktop/….txt by <user>"))
        #expect(count == 3)
        #expect(text.contains("Removed before sending: 3 personal details"))
    }

    /// Reports stay small: the oldest log lines go first.
    @Test func reportsAreCappedByDroppingOldLogLines() {
        let lines = (0..<10_000).map { "line \($0) " + String(repeating: "x", count: 60) }
        let input = BugReportInput(description: "", facts: [], crashes: [], queuedCrashes: [], alerts: [], logs: [("cli.log", lines)])
        let (text, _) = BugReport.build(input, redactor: redactor, created: Date(), maxBytes: 50_000)
        #expect(text.utf8.count <= 50_000)
        #expect(text.contains("line 9999 "))
        #expect(!text.contains("line 0 "))
    }
}

@Suite("Bug report: settings")
struct ReportStateTests {
    @Test func askAfterACrashIsOnByDefaultAndRemembered() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("report-state.json")
        #expect(ReportState.load(from: file).askAfterCrash)
        var s = ReportState.load(from: file)
        s.askAfterCrash = false
        s.lastCrashSeen = Date(timeIntervalSince1970: 1_795_514_400)
        try s.save(to: file)
        let back = ReportState.load(from: file)
        #expect(!back.askAfterCrash && back.lastCrashSeen == Date(timeIntervalSince1970: 1_795_514_400))
    }
}
