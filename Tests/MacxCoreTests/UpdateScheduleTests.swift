import Foundation
import Testing

@testable import MacxCore

@Suite("When a chosen update installs")
struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachChoiceWaitsForItsMoment() {
        let sleep = UpdateSchedule(version: "0.4.0", timing: .whenScreenSleeps, chosen: now)
        #expect(sleep.installs(on: .screenSlept, now: now))
        #expect(!sleep.installs(on: .woke, now: now))
        #expect(!sleep.installs(on: .launched, now: now))
        let wake = UpdateSchedule(version: "0.4.0", timing: .whenMacWakes, chosen: now)
        #expect(wake.installs(on: .woke, now: now))
        #expect(!wake.installs(on: .screenSlept, now: now))
    }

    @Test func aChoiceOlderThanTwoDaysJustAsksAgain() {
        let old = UpdateSchedule(version: "0.4.0", timing: .whenScreenSleeps, chosen: now.addingTimeInterval(-3 * 86_400))
        #expect(!old.installs(on: .screenSlept, now: now))
        #expect(old.isStale(now: now))
    }

    @Test func notNowWaitsADayBeforeAskingAgain() {
        let later = UpdateSchedule(version: "0.4.0", timing: .notNow, chosen: now)
        #expect(!later.shouldAsk(about: "0.4.0", now: now.addingTimeInterval(3600)))
        #expect(later.shouldAsk(about: "0.4.0", now: now.addingTimeInterval(25 * 3600)))
        // A newer version than the one put off is asked about straight away.
        #expect(later.shouldAsk(about: "0.4.1", now: now.addingTimeInterval(60)))
        #expect(UpdateSchedule.none.shouldAsk(about: "0.4.0", now: now))
    }

    @Test func survivesSavingAndLoading() throws {
        let s = UpdateSchedule(version: "0.4.0", timing: .whenMacWakes, chosen: now)
        let back = try JSONDecoder().decode(UpdateSchedule.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
