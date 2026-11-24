import Foundation
import Testing

@testable import MacxCore

/// AMOS asks "am I in a virtual machine?" (system_profiler output compared with VM names) and quits before its
/// payload if so. Benign scripts almost never do that, so the question itself is worth flagging.
@Suite("VM check (anti-analysis)")
struct VMCheckTests {
    @Test(arguments: [
        #"osascript -e 'set r to do shell script "system_profiler SPHardwareDataType"' -e 'if r contains "VMware" then return'"#,
        #"system_profiler SPMemoryDataType | grep -Ei 'QEMU|VirtualBox|Parallels'"#,
        #"if [[ $(sysctl -n hw.model) == *VirtualMac* ]]; then exit 0; fi"#,
        #"ioreg -l | grep -i "Apple Virtual Machine" && exit"#,
        #"case "$(system_profiler SPHardwareDataType)" in *"Apple Virtual Machine"*) exit 0;; esac"#,
    ])
    func flagsVMChecks(_ script: String) {
        #expect(CommandPatterns.match(script).contains(.vmCheck))
    }

    @Test(arguments: [
        "system_profiler SPHardwareDataType | grep 'Model Identifier'",  // plain hardware report
        "sysctl -n hw.optional.arm64",  // Homebrew-style Apple silicon check
        "echo 'Install VMware Fusion from the website'",  // a VM name with no hardware query
        "brew install --cask parallels",
    ])
    func leavesOrdinaryScriptsAlone(_ script: String) {
        #expect(!CommandPatterns.match(script).contains(.vmCheck))
    }

    @Test func vmCheckIsHighNotCritical() {
        #expect(CommandPattern.vmCheck.severity == .high)
        #expect(CommandPattern.quarantineStrip.severity == .high)
        #expect(CommandPattern.base64ToShell.severity == .critical)
    }

    @Test func liveWatchRaisesItAsHigh() throws {
        let line = event(
            "exec", process: proc("/bin/zsh", pid: 4241, platform: true),
            body:
                #"{"target":\#(proc("/usr/bin/osascript", pid: 4242, ppid: 4241, platform: true)),"args":["osascript","-e","do shell script \"system_profiler SPHardwareDataType | grep -i 'Apple Virtual Machine'\""]}"#
        )
        let e = try #require(ESEvent.parse(line))
        let alerts = WatchRules(home: URL(fileURLWithPath: "/Users/v")).evaluate(e)
        #expect(alerts.contains { $0.rule == "vm-check" && $0.severity == .high })
    }

    @Test func scriptInspectionFlagsIt() {
        let script = "#!/bin/zsh\nif system_profiler SPHardwareDataType | grep -qi 'virtual machine'; then exit 0; fi\necho payload\n"
        let url = URL(string: "https://example.invalid/x.sh")!
        let report = ScriptInspector.inspect(Data(script.utf8), url: url, finalURL: url, knownHosts: [])
        #expect(report.behaviours.contains { $0.rule == "vm-check" && $0.severity == .high })
    }

    @Test func multiLineCheckInAScript() {
        let script = "#!/bin/zsh\nhw=$(system_profiler SPHardwareDataType)\nif [[ $hw == *VMware* ]]; then exit 0; fi\n"
        let url = URL(string: "https://example.invalid/y.sh")!
        let report = ScriptInspector.inspect(Data(script.utf8), url: url, finalURL: url, knownHosts: [])
        #expect(report.behaviours.contains { $0.rule == "vm-check" && ($0.detail ?? "").hasPrefix("line 2:") })
    }
}
