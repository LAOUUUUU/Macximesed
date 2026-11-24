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

    @Test func betaOutputReadsTheSame() {
        let up = UpdateReport.parse("macx dev-1a2b3c4 is up to date (beta channel).\n", exitCode: 0)
        #expect(up.status == .upToDate)
        let out = UpdateReport.parse(
            "Warning: the beta file couldn't be read, so only stable releases were checked.\nmacx dev-9f9f9f9 is available (you have dev-1a2b3c4).\n",
            exitCode: 0)
        #expect(out.status == .available("dev-9f9f9f9"))
        #expect(out.warnings.count == 1)
        let installed = UpdateReport.parse("Updated to dev-9f9f9f9. The previous version is kept as macx.previous.\n", exitCode: 0)
        #expect(installed.status == .installed("dev-9f9f9f9"))
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
