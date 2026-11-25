import Foundation
import Testing

@testable import MacxCore

/// The misses and the false alarm from the first Atomic Red Team run (research/independent-testing/PLAN.md), with
/// the tests' real commands. The quiet tests' commands are here too, so a fix can't turn them into false alarms.
@Suite("Atomic Red Team misses")
struct AtomicMissTests {
    let rules = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: [:]))

    /// What the watch says when `sh -c COMMAND` runs (how Invoke-AtomicTest runs a test).
    func shell(_ command: String) -> [WatchAlert] {
        let args = try! JSONSerialization.data(withJSONObject: ["sh", "-c", command])
        let line = event(
            "exec", process: proc("/usr/local/bin/pwsh"),
            body: #"{"target":\#(proc("/bin/sh", platform: true)),"args":\#(String(decoding: args, as: UTF8.self))}"#)
        return rules.evaluate(ESEvent.parse(line)!)
    }

    func exec(_ path: String, _ args: [String], platform: Bool = true, script: String? = nil) -> [WatchAlert] {
        let a = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let s = script.map { #","script":{"path":"\#($0)","path_truncated":false}"# } ?? #","script":null"#
        let line = event(
            "exec", process: proc("/bin/sh", platform: true),
            body: #"{"target":\#(proc(path, platform: platform)),"args":\#(a)\#(s)}"#)
        return rules.evaluate(ESEvent.parse(line)!)
    }

    func ids(_ alerts: [WatchAlert]) -> Set<String> { Set(alerts.map(\.rule)) }
    func loud(_ alerts: [WatchAlert]) -> [String] { alerts.filter { $0.severity >= .medium }.map(\.rule) }

    // MARK: Decode and run, in languages other than the shell

    @Test func pythonExecOfBase64InsideAppleScript() {  // T1059.002 #1
        let cmd =
            #"osascript -e "do shell script \"echo \\\"import sys,base64,warnings;warnings.filterwarnings('ignore');exec(base64.b64decode('aW1wb3J0IHN5cw=='));\\\" | python &\"""#
        #expect(ids(shell(cmd)).contains("base64-to-shell"))
    }

    @Test func pythonDecodesXorAndRunsIt() {  // T1140 #10
        let cmd =
            #"python3 -c 'import base64; import subprocess; xor_decrypt = lambda text, key: "".join([chr(c ^ ord(k)) for c, k in zip(base64.b64decode(text.encode()), key)]); command = "AAkqKQEM"; key = "waEHleblxiQjoxFJQaIMLdHKz"; exec = xor_decrypt(command, key); subprocess.call(exec, shell=True)'"#
        #expect(ids(shell(cmd)).contains("base64-to-shell"))
    }

    @Test func perlAndRubyEvalOfBase64() {
        #expect(ids(shell(#"perl -MMIME::Base64 -e 'eval(decode_base64("cHJpbnQgMQ=="))'"#)).contains("base64-to-shell"))
        #expect(ids(shell(#"ruby -rbase64 -e 'eval(Base64.decode64("cHV0cyAx"))'"#)).contains("base64-to-shell"))
    }

    @Test func decodingAndPrintingStaysQuiet() {  // T1140 #3, #4, #5
        let python =
            #"ENCODED=$(python3 -c 'import base64;enc=base64.b64encode("Hello".encode());print(enc.decode())') python3 -c "import base64;dec=base64.b64decode(\"$ENCODED\");print(dec.decode())""#
        let perl = #"perl -le "use MIME::Base64;print(decode_base64('SGVsbG8='));""#
        let shellDecode = #"ENCODED=$(echo 'Hello' | base64); printf $ENCODED | base64 -d; echo $ENCODED > /tmp/x && base64 -d /tmp/x"#
        for cmd in [python, perl, shellDecode] { #expect(loud(shell(cmd)).isEmpty, "\(cmd)") }
    }

    @Test func decodingIntoAFileAndRunningIt() {  // T1027 #1: the decoded script has no #!, so only the command shows it
        let cmd = """
            if [ "$(uname)" = 'FreeBSD' ]; then cmd="b64decode -r"; else cmd="base64 -d"; fi;
            cat /tmp/encoded.dat | $cmd > /tmp/art.sh
            chmod +x /tmp/art.sh
            /tmp/art.sh
            """
        #expect(ids(shell(cmd)).contains("base64-to-shell"))
        #expect(ids(shell("base64 --decode payload.b64 > /tmp/x.sh; sh /tmp/x.sh")).contains("base64-to-shell"))
        // Decoding to a file that's never run stays quiet.
        #expect(loud(shell("base64 -d in.b64 > /tmp/out.bin; ls -l /tmp/out.bin")).isEmpty)
    }

    // MARK: Scripts from temporary folders

    @Test func scriptRunByItsShebangFromTmp() {  // T1027 #1: /tmp/art.sh run directly
        let a = exec("/bin/sh", ["/bin/sh", "/tmp/art.sh"], script: "/tmp/art.sh")
        #expect(a.contains { $0.rule == "exec-from-hidden-or-temp" && $0.severity >= .medium })
    }

    @Test func installerScriptsAndScriptsPassedAsArgumentsStayQuiet() {
        // macOS Installer's own sandbox, and `sh /tmp/x.sh` (T1059.004 #1, expected quiet).
        let pkg = exec(
            "/bin/sh", ["/bin/sh", "/private/tmp/PKInstallSandbox.AbC/Scripts/x/postinstall"],
            script: "/private/tmp/PKInstallSandbox.AbC/Scripts/x/postinstall")
        #expect(loud(pkg).isEmpty)
        #expect(loud(exec("/bin/sh", ["sh", "/tmp/art.sh"])).isEmpty)
    }

    // MARK: Dodging analysis

    @Test func modelNameChecksAreVMChecks() {  // T1497.001 #6, #8
        #expect(
            ids(shell(#"if [ "$(sysctl -n hw.model | grep -v 'Mac')" != "" ]; then echo 'Virtualization Environment detected'; fi;"#))
                .contains("vm-check"))
        #expect(
            ids(shell(#"if [ "$(system_profiler SPHardwareDataType | grep "Model Identifier" | grep -v 'Mac')" != "" ]; then echo x; fi;"#))
                .contains("vm-check"))
        // Reading the model on its own is not a check.
        #expect(loud(shell("sysctl -n hw.model")).isEmpty)
    }

    // MARK: Background jobs without a launch file

    @Test func launchctlSubmit() {  // T1569.001 #1
        let a = exec(
            "/bin/launchctl", ["launchctl", "submit", "-l", "evil", "--", "/System/Applications/Calculator.app/Contents/MacOS/Calculator"])
        #expect(a.contains { $0.rule == "new-launch-item" && $0.severity == .medium })
        #expect(loud(exec("/bin/launchctl", ["launchctl", "list"])).isEmpty)
    }

    // MARK: Stealing from the keychain and browsers (by command; reading files directly needs `open` events)

    @Test func keychainDumpAndCopy() {  // T1555.001 #1, #4
        #expect(ids(exec("/usr/bin/security", ["security", "dump-keychain", "-d", "login.keychain"])).contains("keychain-read"))
        #expect(ids(shell("cat ~/Library/Keychains/login.keychain-db > /tmp/keychain")).contains("keychain-read"))
        #expect(
            ids(exec("/usr/bin/security", ["security", "find-generic-password", "-ws", "Chrome Safe Storage"])).contains("keychain-read"))
        // An ordinary password lookup by a script (git credential helpers do this) isn't flagged.
        #expect(loud(exec("/usr/bin/security", ["security", "find-generic-password", "-s", "github.com", "-w"])).isEmpty)
    }

    @Test func browserPasswordsAndCookies() {  // T1555.003 #2, #14, #18
        #expect(
            ids(shell(#"cp ~/Library/"Application Support/Google/Chrome/Default/Login Data" "/tmp/T1555.003_Login Data""#))
                .contains("browser-data-read"))
        #expect(
            ids(
                shell(
                    #"sqlite3 "file:$HOME/Library/Application Support/Google/Chrome/Default/Login Data?immutable=1" "SELECT origin_url, username_value FROM logins;" > /tmp/o"#
                )
            ).contains("browser-data-read"))
        #expect(ids(shell(#"cd ~/Library/Cookies; grep -q "coinbase" "Cookies.binarycookies""#)).contains("browser-data-read"))
        #expect(
            ids(exec("/bin/cp", ["cp", "/Users/v/Library/Application Support/Google/Chrome/Default/Login Data", "/tmp/x"], platform: true))
                .contains("browser-data-read"))
    }

    // MARK: The false alarm: developer tools in dot-folders

    @Test func toolchainsInDotFoldersAreLowButHiddenProgramsStayHigh() {
        let rustc = exec("/Users/v/.rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc", ["rustc", "-V"], platform: false)
        #expect(rustc.contains { $0.rule == "exec-from-hidden-or-temp" && $0.severity == .low })
        // AMOS's backdoor sits right in the home folder as a hidden file (~/.helper): still high.
        let helper = exec("/Users/v/.helper", [".helper"], platform: false)
        #expect(helper.contains { $0.rule == "exec-from-hidden-or-temp" && $0.severity == .high })
        // A hidden folder in Application Support, and /tmp, stay high too.
        let support = exec("/Users/v/Library/Application Support/.x/run", ["run"], platform: false)
        #expect(support.contains { $0.severity == .high })
        #expect(exec("/tmp/evil", ["evil"], platform: false).contains { $0.severity == .high })
    }
}
