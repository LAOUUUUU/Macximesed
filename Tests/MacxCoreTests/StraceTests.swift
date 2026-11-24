import Foundation
import Testing

@testable import MacxCore

/// The light chamber records the sample with `strace -f -ttt -qq -s 4096 -e trace=execve,openat,rename,renameat2,connect,clone,clone3,fork,vfork`.
/// Lines look like `PID EPOCH.MICROS syscall(args) = result`.
@Suite("Light chamber: strace lines to events")
struct StraceTests {
    func events(_ text: String) -> [ESEvent] { StraceLog.parse(text).events }

    @Test func execWithArgumentsAndParentFromClone() throws {
        let e = events(
            """
            500 1795514401.000100 clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID|SIGCHLD, child_tidptr=0xffff) = 501
            501 1795514401.000200 execve("/usr/bin/osascript", ["osascript", "-e", "display dialog \\"Password\\" default answer \\"\\" with hidden answer"], 0xffffe0 /* 5 vars */) = 0
            """)
        let exec = try #require(e.first { $0.kind == "exec" })
        #expect(exec.target?.path == "/usr/bin/osascript")
        #expect(exec.target?.pid == 501)
        #expect(exec.target?.ppid == 500)
        #expect(exec.args == ["osascript", "-e", #"display dialog "Password" default answer "" with hidden answer"#])
        #expect(abs((exec.time?.timeIntervalSince1970 ?? 0) - 1_795_514_401.0002) < 0.000_01)
    }

    @Test func failedCallsAreDropped() {
        let e = events(
            """
            500 1795514401.1 execve("/usr/local/bin/brew", ["brew"], 0x1 /* 1 var */) = -1 ENOENT (No such file or directory)
            500 1795514401.2 openat(AT_FDCWD, "/nope", O_RDONLY) = -1 ENOENT (No such file or directory)
            """)
        #expect(e.isEmpty)
    }

    @Test func openAndCreate() {
        let e = events(
            """
            500 1795514401.3 openat(AT_FDCWD, "/Users/chamber/Library/Keychains/login.keychain-db", O_RDONLY|O_CLOEXEC) = 3
            500 1795514401.4 openat(AT_FDCWD, "/Library/LaunchDaemons/com.apple.helper.plist", O_WRONLY|O_CREAT|O_TRUNC, 0644) = 4
            """)
        #expect(e.map(\.kind) == ["open", "open", "create"])
        #expect(e[0].filePath == "/Users/chamber/Library/Keychains/login.keychain-db")
        #expect(e[2].filePath == "/Library/LaunchDaemons/com.apple.helper.plist")
        #expect(e[2].process?.pid == 500)
    }

    @Test func relativePathsUseTheCurrentDirectoryWhenKnown() {
        // Relative paths can't be resolved without the cwd; they're kept as written and marked.
        let e = events(#"500 1795514401.5 openat(AT_FDCWD, "notes.txt", O_RDONLY) = 3"#)
        #expect(e.first?.filePath == "notes.txt")
    }

    @Test func renameGivesSourceAndDestination() {
        let e = events(
            #"500 1795514401.6 renameat2(AT_FDCWD, "/tmp/x.plist", AT_FDCWD, "/Library/LaunchDaemons/com.apple.x.plist", 0) = 0"#)
        #expect(e.first?.kind == "rename")
        #expect(e.first?.sourcePath == "/tmp/x.plist")
        #expect(e.first?.filePath == "/Library/LaunchDaemons/com.apple.x.plist")
    }

    @Test func networkAttemptsAreRecordedEvenWhenTheyFail() {
        // There's no network in the chamber, so connect always fails; the attempt is what matters.
        let e = events(
            #"501 1795514401.7 connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.9")}, 16) = -1 ENETUNREACH (Network is unreachable)"#
        )
        #expect(e.first?.kind == "connect")
        #expect(e.first?.filePath == "203.0.113.9:443")
        // Local sockets aren't network.
        #expect(events(#"501 1795514401.8 connect(3, {sa_family=AF_UNIX, sun_path="/var/run/x"}, 110) = -1 ENOENT (No such file)"#).isEmpty)
    }

    @Test func unfinishedAndResumedCallsAreJoined() {
        let e = events(
            """
            500 1795514401.9 openat(AT_FDCWD, "/Users/chamber/Library/Application Support/Google/Chrome/Default/Login Data", O_RDONLY <unfinished ...>
            501 1795514401.91 clone(child_stack=NULL, flags=SIGCHLD) = 502
            500 1795514401.92 <... openat resumed>) = 5
            """)
        #expect(e.contains { $0.kind == "open" && $0.filePath?.hasSuffix("/Login Data") == true })
    }

    @Test func exitLines() {
        let e = events("500 1795514402.0 +++ exited with 0 +++")
        #expect(e.first?.kind == "exit")
        #expect(e.first?.process?.pid == 500)
    }

    @Test func consoleLineEndingsAreSplit() {
        // The VM's console turns "\n" into "\r\n", which Swift treats as one character.
        let text = "500 1795514401.3 openat(AT_FDCWD, \"/a\", O_RDONLY) = 3\r\n500 1795514401.4 openat(AT_FDCWD, \"/b\", O_RDONLY) = 4\r\n"
        #expect(events(text).compactMap(\.filePath) == ["/a", "/b"])
    }

    @Test func junkIsSkippedAndCounted() {
        let log = StraceLog.parse("hello\n500 not-a-time execve(\"/x\") = 0\n\n")
        #expect(log.events.isEmpty)
        #expect(log.skipped == 2)
    }

    @Test func octalAndHexEscapesInStrings() {
        let e = events(#"500 1795514403.0 openat(AT_FDCWD, "/tmp/a\303\251\x41\tb", O_RDONLY) = 3"#)
        #expect(e.first?.filePath == "/tmp/aéA\tb")
    }

    @Test func judgedLikeTheGuestLog() {
        // The same judge decides: a keychain read by the sample's child is critical.
        let text = """
            500 1795514401.0 clone(child_stack=NULL, flags=SIGCHLD) = 501
            501 1795514401.1 execve("/usr/bin/security", ["security", "dump-keychain"], 0x1 /* 1 var */) = 0
            501 1795514401.2 openat(AT_FDCWD, "/Users/chamber/Library/Keychains/login.keychain-db", O_RDONLY) = 3
            """
        let r = ChamberJudge(guestHome: URL(fileURLWithPath: "/Users/chamber")).judge(events: StraceLog.parse(text).events, samplePID: 500)
        #expect(r.verdict == .dangerous)
        #expect(r.alerts.contains { $0.rule == "reads-keychain" })
    }

    @Test func networkAttemptIsAChamberRule() {
        let text =
            #"500 1795514401.0 connect(3, {sa_family=AF_INET6, sin6_port=htons(80), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "2001:db8::1", &sin6_addr), sin6_scope_id=0}, 28) = -1 ENETUNREACH (Network is unreachable)"#
        let r = ChamberJudge(guestHome: URL(fileURLWithPath: "/Users/chamber")).judge(events: StraceLog.parse(text).events, samplePID: 500)
        #expect(r.alerts.contains { $0.rule == "network-attempt" && $0.severity == .medium && ($0.detail ?? "") == "[2001:db8::1]:80" })
    }
}

/// A real run: the light chamber booted (Alpine 3.24.4 kernel, 1.6 s) and ran a harmless pretend stealer
/// (fake password box, bait keychain read, connect to a TEST-NET address, fake Apple launch item).
@Suite("Light chamber: a real recorded run")
struct RealChamberRunTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/chamber-strace-pretend-stealer.txt")

    @Test func judgedDangerousWithEveryStep() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        let parsed = StraceLog.parse(text)
        #expect(parsed.skipped == 0)
        // The first process in the trace is the sample (timeout, then bash in the same pid).
        let sample = try #require(parsed.events.first?.process?.pid)
        let r = ChamberJudge(guestHome: URL(fileURLWithPath: "/Users/chamber")).judge(events: parsed.events, samplePID: sample)
        let rules = Set(r.alerts.map(\.rule))
        #expect(r.verdict == .dangerous)
        #expect(rules.isSuperset(of: ["password-prompt", "reads-keychain", "network-attempt", "fake-apple-launch-item"]))
        #expect(r.alerts.first { $0.rule == "network-attempt" }?.detail == "203.0.113.9:443")
    }
}
