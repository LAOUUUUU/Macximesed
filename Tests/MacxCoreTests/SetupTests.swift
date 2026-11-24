import Foundation
import Testing

@testable import MacxCore

@Suite("First-run setup")
struct SetupTests {
    @Test func setupShowsOnceUntilFinishedOrSkipped() {
        #expect(FirstRun.shouldShowSetup(finished: nil))
        #expect(FirstRun.shouldShowSetup(finished: "0.2.0") == false)
        // A later version doesn't bring it back by itself: Settings has "Run setup again".
        #expect(FirstRun.shouldShowSetup(finished: "0.1.0") == false)
    }

    @Test func stepsKnowWhenTheyAreDone() {
        let fresh = SetupFacts(fullDiskAccess: false, watch: .notInstalled, notifications: .notAsked)
        #expect(fresh.isDone(.fullDiskAccess) == false)
        #expect(fresh.isDone(.watch) == false)
        #expect(fresh.isDone(.notifications) == false)
        let set = SetupFacts(fullDiskAccess: true, watch: .watching(since: Date()), notifications: .allowed)
        #expect(set.isDone(.fullDiskAccess) && set.isDone(.watch) && set.isDone(.notifications))
        // Paused still counts as installed and running.
        #expect(SetupFacts(fullDiskAccess: true, watch: .paused(until: Date()), notifications: .denied).isDone(.watch))
        #expect(SetupFacts(fullDiskAccess: true, watch: .starting, notifications: .denied).isDone(.watch) == false)
    }

    @Test func refusedWatchSendsYouBackToFullDiskAccess() {
        let f = SetupFacts(fullDiskAccess: true, watch: .refused(message: "not permitted"), notifications: .notAsked)
        #expect(f.watchNeedsFullDiskAccess)
        #expect(SetupFacts(fullDiskAccess: true, watch: .notInstalled, notifications: .notAsked).watchNeedsFullDiskAccess == false)
    }
}

@Suite("Notifications: app or daemon")
struct NotifyRouteTests {
    let app = "/Users/v/Applications/Macximesed.app/Contents/MacOS/macx"

    @Test func appProcessIsTheBundleBinaryRunWithoutACommandByTheUser() {
        #expect(AppPresence.isApp(path: app, arguments: [app], uid: 501, userUID: 501))
        #expect(AppPresence.isApp(path: app, arguments: [app, "-psn_0_42"], uid: 501, userUID: 501))
        #expect(AppPresence.isApp(path: app, arguments: [app, "app"], uid: 501, userUID: 501))
        // The daemon (root), a CLI run, another user's app, and some other program are not the app.
        #expect(AppPresence.isApp(path: app, arguments: [app, "watch", "--background"], uid: 0, userUID: 501) == false)
        #expect(AppPresence.isApp(path: app, arguments: [app, "alerts", "--follow"], uid: 501, userUID: 501) == false)
        #expect(AppPresence.isApp(path: app, arguments: [app], uid: 502, userUID: 501) == false)
        #expect(AppPresence.isApp(path: "/tmp/Macximesed.app/Contents/MacOS/evil", arguments: ["x"], uid: 501, userUID: 501) == false)
        #expect(AppPresence.isApp(path: "/usr/local/bin/macx", arguments: ["macx"], uid: 501, userUID: 501) == false)
    }

    @Test func readsArgumentsFromKernProcargs2() {
        // argc, exec path, padding NULs, then argv; environment after.
        var buf = Data()
        var argc: Int32 = 2
        buf.append(Data(bytes: &argc, count: 4))
        buf.append(Data("/x/macx\0\0\0".utf8))
        buf.append(Data("/x/macx\0watch\0HOME=/var/root\0".utf8))
        #expect(AppPresence.parseProcargs2(buf) == ["/x/macx", "watch"])
        #expect(AppPresence.parseProcargs2(Data([1, 0])) == nil)
    }

    @Test func appPostsOnlyNewSeriousAlertsThrottled() {
        let start = Date(timeIntervalSince1970: 1_000)
        func r(_ sev: Severity, _ t: Double, _ rule: String = "x") -> AlertRecord {
            AlertRecord(time: Date(timeIntervalSince1970: t), rule: rule, severity: sev, title: "T\(Int(t))", detail: "", process: "/p")
        }
        var n = AppNotifications(started: start)
        // Old alerts (before the app opened), medium ones and bookkeeping are never posted.
        #expect(
            n.offer([r(.critical, 900), r(.medium, 1_001), r(.info, 1_002, "frozen")], now: Date(timeIntervalSince1970: 1_003)).isEmpty)
        let first = n.offer([r(.high, 1_010), r(.critical, 1_011)], now: Date(timeIntervalSince1970: 1_011))
        #expect(first.map(\.body) == ["T1011"])  // most severe of the batch; the other is held
        #expect(first.first?.title == "Macximesed: CRITICAL")
        let later = n.offer([r(.high, 1_030)], now: Date(timeIntervalSince1970: 1_030))
        #expect(later.first?.body == "T1030 (and 1 more: macx alerts)")
    }
}
