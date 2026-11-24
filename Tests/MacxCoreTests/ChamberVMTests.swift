import Foundation
import Testing

@testable import MacxCore

@Suite("Light chamber VM plumbing")
struct ChamberVMTests {
    @Test func consoleIsSplitIntoTraceAndOutput() {
        let console =
            "[    0.1] boot noise\r\n==MACX-READY==\r\n==MACX-TRACE==\r\n500 1.0 execve(\"/bin/zsh\", [\"zsh\"], 0x1 /* 1 var */) = 0\r\n==MACX-END==\r\n==MACX-OUTPUT==\r\nhello\r\n\r\n==MACX-OUTPUT-END==\r\n"
        let c = ChamberConsole.parse(console)
        #expect(c.ready)
        #expect(c.trace == "500 1.0 execve(\"/bin/zsh\", [\"zsh\"], 0x1 /* 1 var */) = 0")
        #expect(c.output == "hello")
        #expect(c.complete)
    }

    @Test func aRunThatNeverFinishedIsIncomplete() {
        let c = ChamberConsole.parse("==MACX-READY==\n==MACX-TRACE==\n500 1.0 openat(AT_FDCWD, \"/a\", O_RDONLY) = 3\n")
        #expect(c.ready)
        #expect(!c.complete)
        #expect(c.trace.contains("openat"))
    }

    @Test func resealKeepsTheVirtualizationEntitlement() {
        let args = SigningIdentity.resealArguments(
            sign: "ABC", id: "dev.macximesed.macx", app: URL(fileURLWithPath: "/A/Macximesed.app"),
            entitlements: URL(fileURLWithPath: "/tmp/e.plist"))
        #expect(
            args == [
                "--force", "--sign", "ABC", "--identifier", "dev.macximesed.macx", "--entitlements", "/tmp/e.plist", "/A/Macximesed.app",
            ])
    }

    @Test func entitlementsMatchTheInstallerCopy() throws {
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: Data(SigningIdentity.entitlementsPlist.utf8), format: nil) as? [String: Any])
        #expect(plist["com.apple.security.virtualization"] as? Bool == true)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/macx.entitlements")
        #expect(try String(contentsOf: file, encoding: .utf8) == SigningIdentity.entitlementsPlist)
    }
}
