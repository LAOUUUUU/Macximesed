import Foundation
import Testing

@testable import MacxCore

@Suite("Why it's slow")
struct SlowdownAdvisorTests {
    func use(_ path: String, _ cpu: Double, pid: Int32 = 100, mem: UInt64 = 0) -> CPUUse {
        CPUUse(pid: pid, uid: 501, path: path, cpuPercent: cpu, memoryBytes: mem)
    }

    @Test func photosAnalysisIsNamedByItsExactPath() {
        let found = SlowdownAdvisor.explain(
            uses: [use("/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd", 80)], front: nil)
        #expect(found.first?.kind == .photosAnalysis)
        #expect(found.first?.advice.contains("plugged in") == true)
        // A program that only borrows the name isn't Apple's.
        let fake = SlowdownAdvisor.explain(uses: [use("/Users/v/Library/.x/photoanalysisd", 80)], front: nil)
        #expect(!fake.contains { $0.kind == .photosAnalysis })
    }

    @Test func aBackgroundAppIsAHogButTheFrontOneIsNot() {
        let roblox = "/Applications/Roblox.app/Contents/MacOS/RobloxPlayer"
        let bg = SlowdownAdvisor.explain(uses: [use(roblox, 30, pid: 10050)], front: "/Applications/Safari.app")
        let hog = bg.first { $0.kind == .backgroundApp }
        #expect(hog?.appPath == "/Applications/Roblox.app")
        #expect(hog?.title.contains("Roblox") == true)
        #expect(hog?.title.contains("30%") == true)
        let front = SlowdownAdvisor.explain(uses: [use(roblox, 30)], front: "/Applications/Roblox.app")
        #expect(!front.contains { $0.kind == .backgroundApp })
    }

    @Test func helpersCountTowardsTheirApp() {
        let uses = [
            use(
                "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)", 9,
                pid: 1),
            use("/Applications/Discord.app/Contents/Frameworks/Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)", 8, pid: 2),
        ]
        let hog = SlowdownAdvisor.explain(uses: uses, front: nil).first { $0.kind == .backgroundApp }
        #expect(hog?.appPath == "/Applications/Discord.app")
        #expect(hog?.title.contains("17%") == true)
    }

    @Test func quietAppsAndAppleAppsAreNotHogs() {
        let found = SlowdownAdvisor.explain(
            uses: [
                use("/Applications/Spotify.app/Contents/MacOS/Spotify", 3), use("/System/Applications/Mail.app/Contents/MacOS/Mail", 40),
            ],
            front: nil)
        #expect(!found.contains { $0.kind == .backgroundApp })
    }

    @Test func webPagesVideoSpotlightAndWindowServerAreExplained() {
        let found = SlowdownAdvisor.explain(
            uses: [
                use(
                    "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                    32),
                use(
                    "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService",
                    20),
                use(
                    "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds_stores",
                    40),
                use("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", 45),
            ], front: nil)
        #expect(Set(found.map(\.kind)) == [.webPage, .videoDecoding, .spotlight, .windowServer])
    }

    @Test func memoryBatteryAndDiskNotes() {
        let tight = MemoryState(pressure: .warning, physicalBytes: 16 << 30, swapUsedBytes: 2 << 30, swapTotalBytes: 3 << 30)
        let found = SlowdownAdvisor.explain(uses: [], front: nil, memory: tight, onBattery: true, diskFreeFraction: 0.06)
        #expect(Set(found.map(\.kind)) == [.memoryTight, .onBattery, .diskNearlyFull])
        #expect(SlowdownAdvisor.explain(uses: [], front: nil, memory: nil, onBattery: false, diskFreeFraction: 0.5).isEmpty)
    }

    @Test func appBundleIsTheOutermostApp() {
        #expect(
            SlowdownAdvisor.appBundle(of: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/x")
                == "/Applications/Claude.app")
        #expect(SlowdownAdvisor.appBundle(of: "/usr/bin/python3") == nil)
    }
}
