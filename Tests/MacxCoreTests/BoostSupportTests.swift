import Foundation
import Testing

@testable import MacxCore

@Suite("Boost support: finding apps, reading a measurement")
struct BoostSupportTests {
    @Test func findsAnAppByNameInEitherApplicationsFolder() throws {
        let tmp = try TempDir()
        let sys = tmp.url.appendingPathComponent("Applications")
        let user = tmp.url.appendingPathComponent("home/Applications")
        _ = try tmp.file("Applications/Slack.app/Contents/Info.plist", "x")
        _ = try tmp.file("home/Applications/Balatro.app/Contents/Info.plist", "x")
        let roots = [sys, user]
        #expect(AppLocator.find("slack", in: roots)?.lastPathComponent == "Slack.app")
        #expect(AppLocator.find("Balatro.app", in: roots)?.lastPathComponent == "Balatro.app")
        #expect(AppLocator.find("nope", in: roots) == nil)
        // A path is taken as it is.
        #expect(AppLocator.find(sys.appendingPathComponent("Slack.app").path, in: []) != nil)
    }

    @Test func measurementsWithinNoiseAreCalledNoise() {
        #expect(BoostMeasurement(baseline: 1000, boosted: 1020).verdict == .noise)
        #expect(BoostMeasurement(baseline: 1000, boosted: 1100).verdict == .faster)
        #expect(BoostMeasurement(baseline: 1000, boosted: 900).verdict == .slower)
        #expect(abs(BoostMeasurement(baseline: 1000, boosted: 1100).percent - 10) < 0.01)
    }
}
