import Foundation
import Testing

@testable import MacxCore

@Suite("Quarantine removal, checked with Gatekeeper")
struct QuarantineReviewTests {
    func high(_ file: String, by process: String = "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.10/bin/ruby") -> WatchAlert {
        WatchAlert(
            rule: "quarantine-removed", severity: .high,
            title: "The download-safety (quarantine) flag was removed, so macOS won't check this file",
            detail: file, pid: 30028, processPath: process)
    }

    let notarized = GatekeeperResult(
        accepted: true, source: "Notarized Developer ID", origin: "Developer ID Application: Obsidian (6JSW4SJWN9)")

    @Test func onlyHighQuarantineAlertsWithAPathWaitForGatekeeper() {
        #expect(QuarantineReview.needsReview(high("/Applications/Obsidian.app")))
        var low = high("/Applications/Obsidian.app")
        low.severity = .low
        #expect(!QuarantineReview.needsReview(low))
        var noPath = high("")
        noPath.detail = nil
        #expect(!QuarantineReview.needsReview(noPath))
        var other = high("/Applications/Obsidian.app")
        other.rule = "network"
        #expect(!QuarantineReview.needsReview(other))
    }

    @Test func aNotarizedAppGatekeeperAcceptsIsLow() {
        // Homebrew's ruby isn't signed, so the rule says high; Gatekeeper would have let Obsidian through anyway.
        let a = QuarantineReview.review(high("/Applications/Obsidian.app"), gatekeeper: notarized)
        #expect(a.severity == .low)
        #expect(a.rule == "quarantine-removed")
        #expect(a.title.contains("notarized"))
        #expect(a.detail?.contains("/Applications/Obsidian.app") == true)
        #expect(a.detail?.contains("Obsidian (6JSW4SJWN9)") == true)
        #expect(a.pid == 30028)
    }

    @Test func applesOwnSoftwareIsLowToo() {
        let a = QuarantineReview.review(
            high("/Users/v/Downloads/Tool.pkg"), gatekeeper: GatekeeperResult(accepted: true, source: "Apple System", origin: nil))
        #expect(a.severity == .low)
    }

    @Test func signedButNotNotarizedStaysHigh() {
        let a = QuarantineReview.review(
            high("/Users/v/Downloads/Thing.app"),
            gatekeeper: GatekeeperResult(accepted: true, source: "Developer ID", origin: "Developer ID Application: Someone (ABCDE12345)"))
        #expect(a.severity == .high)
        #expect(a.detail?.contains("not notarized") == true)
    }

    @Test func somethingGatekeeperWouldBlockStaysHighAndSaysSo() {
        let a = QuarantineReview.review(
            high("/Users/v/Library/Application Support/.helper/run"),
            gatekeeper: GatekeeperResult(accepted: false, error: "code has no resources but signature indicates they must be present"))
        #expect(a.severity == .high)
        #expect(a.title.contains("Gatekeeper would block"))
        #expect(a.detail?.contains("no resources") == true)
    }

    @Test func picksTheGatekeeperCheckByFileType() {
        #expect(QuarantineReview.kind(for: "/Applications/Obsidian.app") == .execute)
        #expect(QuarantineReview.kind(for: "/Users/v/Downloads/loader") == .execute)
        #expect(QuarantineReview.kind(for: "/Users/v/Downloads/Setup.pkg") == .install)
        #expect(QuarantineReview.kind(for: "/Users/v/Downloads/Setup.dmg") == .open)
    }

    @Test func theRuleItselfStillSaysHighForAnUnsignedProgram() {
        // The review only ever lowers an alert after Gatekeeper answers; the rule doesn't trust Homebrew by path.
        let body = #"{"target":{"path":"/Applications/Obsidian.app","path_truncated":false},"extattr":"com.apple.quarantine"}"#
        let rules = WatchRules(home: URL(fileURLWithPath: "/Users/v"), signatures: FakeSignatures(byPath: [:]))
        let line = event(
            "deleteextattr",
            process: proc(
                "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.10/bin/ruby", pid: 30028, platform: false, team: nil),
            body: body)
        let a = rules.evaluate(ESEvent.parse(line)!)
        #expect(a.first?.severity == .high)
        #expect(QuarantineReview.needsReview(a[0]))
    }
}
