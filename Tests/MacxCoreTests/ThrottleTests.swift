import Foundation
import Testing

@testable import MacxCore

@Suite("Throttle view: CPU use, thermal pressure, heat graph")
struct ThrottleTests {
    @Test func cpuUseComesFromCPUTimeBetweenTwoSnapshots() {
        let before: [Int32: CPUSampler.Reading] = [
            10: .init(cpuNanos: 1_000_000_000, uid: 501, path: "/Applications/Game.app/Contents/MacOS/Game"),
            11: .init(cpuNanos: 5_000_000_000, uid: 501, path: "/Applications/Slack.app/Contents/MacOS/Slack"),
            12: .init(cpuNanos: 0, uid: 501, path: "/gone"),
        ]
        let after: [Int32: CPUSampler.Reading] = [
            10: .init(cpuNanos: 2_500_000_000, uid: 501, path: "/Applications/Game.app/Contents/MacOS/Game"),  // 1.5 s of CPU in 1 s
            11: .init(cpuNanos: 5_250_000_000, uid: 501, path: "/Applications/Slack.app/Contents/MacOS/Slack"),
            13: .init(cpuNanos: 9_000_000_000, uid: 501, path: "/new"),  // started in between: no baseline, skipped
        ]
        let uses = CPUSampler.uses(before: before, after: after, interval: 1.0)
        #expect(uses.map(\.pid) == [10, 11])
        #expect(abs(uses[0].cpuPercent - 150) < 0.01)
        #expect(abs(uses[1].cpuPercent - 25) < 0.01)
    }

    @Test(arguments: [(0, "Nominal"), (1, "Moderate"), (2, "Heavy"), (3, "Trapping"), (4, "Sleeping"), (9, "Unknown")])
    func pressureLabels(_ level: Int, _ label: String) {
        #expect(ThermalPressure(level: level).label == label)
    }

    @Test func heatGraphIsFixedWidth() {
        var t = HeatTimeline()
        for (i, level) in [ThermalLevel.nominal, .nominal, .fair, .serious, .critical, .fair].enumerated() {
            t.add(
                HeatTimeline.Sample(
                    time: Date(timeIntervalSince1970: Double(i) * 2), level: level, pressure: nil, cpuPercent: Double(i * 20)))
        }
        let strip = t.levelStrip(width: 6)
        #expect(strip.count == 6)
        #expect(strip == "▁▁▃▅█▃")
        #expect(t.loadStrip(width: 6).count == 6)
        // More samples than columns: averaged into the width.
        #expect(t.levelStrip(width: 3).count == 3)
        #expect(t.peak == .critical)
        #expect(abs(t.secondsThrottled - 4) < 0.01)  // serious and critical samples, 2 s apart
    }

    @Test func emptyTimeline() {
        let t = HeatTimeline()
        #expect(t.levelStrip(width: 10) == "")
        #expect(t.peak == nil)
    }
}
