import Testing

@testable import MacxCore

@Suite("What the app shows after an update check")
struct UpdateReportTests {
    @Test func aNewVersionIsTheHeadlineNotTheHashFeed() {
        let r = UpdateReport.parse(
            "Malware hash feed: 1 known sample (checked offline).\nmacx 0.3.0 is available (you have 0.2.0).\n", exitCode: 0)
        #expect(r.status == .available("0.3.0"))
        #expect(r.feed == "Malware hash feed: 1 known sample (checked offline).")
    }

    @Test func upToDate() {
        let r = UpdateReport.parse("Malware hash feed: 3 known samples (checked offline).\nmacx 0.3.0 is up to date.\n", exitCode: 0)
        #expect(r.status == .upToDate)
    }

    @Test func aSecurityProblemIsAvailableAndUrgent() {
        let r = UpdateReport.parse(
            "Your version has a security problem: CVE-1\nmacx 0.3.1 is available (you have 0.3.0).\n", exitCode: 0)
        #expect(r.status == .urgent("0.3.1", reason: "CVE-1"))
    }

    @Test func installedAfterAnInstall() {
        let r = UpdateReport.parse(
            "macx 0.3.0 is available (you have 0.2.0).\nUpdated to 0.3.0. The previous version is kept as macx.previous.\n", exitCode: 0)
        #expect(r.status == .installed("0.3.0"))
    }

    @Test func failuresShowTheErrorLine() {
        let r = UpdateReport.parse("Downloading macx 0.3.0…\nError: Couldn't get the update channel: timed out\n", exitCode: 1)
        #expect(r.status == .failed("Couldn't get the update channel: timed out"))
        #expect(UpdateReport.parse("", exitCode: 1).status == .failed("Couldn't check."))
    }

    @Test func warningsAreKept() {
        let r = UpdateReport.parse(
            "The update file is older than one macx has already seen, so it was ignored (a rollback attempt?).\nmacx 0.3.0 is up to date.\n",
            exitCode: 0)
        #expect(r.warnings.count == 1)
    }

    @Test func feedCountReadsRight() {
        #expect(HashFeedLine.text(count: 1) == "Malware hash feed: 1 known sample (checked offline).")
        #expect(HashFeedLine.text(count: 12) == "Malware hash feed: 12 known samples (checked offline).")
    }
}
