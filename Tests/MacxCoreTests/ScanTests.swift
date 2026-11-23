import Foundation
import Testing

@testable import MacxCore

@Suite("Process list parsing")
struct ProcessListTests {
    @Test func parsesPsLines() {
        let out = """
            43227  45.0  29776 /usr/libexec/searchpartyuseragent
              912   3.1 739136 /Applications/Some Game.app/Contents/MacOS/Some Game
            """
        let procs = ProcessSample.parse(psOutput: out)
        #expect(procs.count == 2)
        #expect(procs[0].pid == 43227)
        #expect(procs[0].cpuPercent == 45.0)
        #expect(procs[0].memoryBytes == 29776 * 1024)
        #expect(procs[0].name == "searchpartyuseragent")
        #expect(procs[1].path == "/Applications/Some Game.app/Contents/MacOS/Some Game")
        #expect(procs[1].name == "Some Game")
    }

    @Test func skipsMalformedLines() {
        let procs = ProcessSample.parse(psOutput: "garbage\n\n12 x 3 /bin/ls\n7 1.0 20 /bin/sh\n")
        #expect(procs.map(\.pid) == [7])
    }

    @Test func topSortsByCPUAndLimits() {
        let procs = [
            ProcessSample(pid: 1, cpuPercent: 1, memoryBytes: 0, path: "/a"),
            ProcessSample(pid: 2, cpuPercent: 9, memoryBytes: 0, path: "/b"),
            ProcessSample(pid: 3, cpuPercent: 5, memoryBytes: 0, path: "/c"),
        ]
        #expect(ProcessSample.top(procs, limit: 2).map(\.pid) == [2, 3])
    }
}

@Suite("Thermal state")
struct ThermalTests {
    @Test func mapsProcessInfoStates() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.critical) == .critical)
        #expect(ThermalLevel.serious.isThrottling)
        #expect(!ThermalLevel.fair.isThrottling)
    }
}

@Suite("Byte formatting")
struct ByteFormatTests {
    @Test func formats() {
        #expect(formatBytes(512) == "512 B")
        #expect(formatBytes(1536) == "1.5 KB")
        #expect(formatBytes(10 * 1024 * 1024 * 1024) == "10.0 GB")
    }
}

@Suite("Scan report text")
struct ReportTests {
    @Test func flagsProtectionsThatAreOff() {
        let report = ScanReport(
            protections: Protections(sip: .on, gatekeeper: .off, fileVault: .on, firewall: .unknown),
            topProcesses: [ProcessSample(pid: 5, cpuPercent: 12.5, memoryBytes: 2048, path: "/usr/bin/hog")],
            disk: DiskUsage(totalBytes: 1000, availableBytes: 100),
            thermal: .serious
        )
        let text = report.render()
        #expect(text.contains("SIP"))
        #expect(text.contains("Gatekeeper") && text.contains("OFF"))
        #expect(text.contains("hog"))
        #expect(text.contains("12.5%"))
        #expect(text.contains("90% used"))
        #expect(text.contains("throttling"))
        #expect(report.warnings.contains { $0.contains("Gatekeeper") })
        #expect(report.warnings.contains { $0.contains("Disk") })
    }

    @Test func healthyReportHasNoWarnings() {
        let report = ScanReport(
            protections: Protections(sip: .on, gatekeeper: .on, fileVault: .on, firewall: .on),
            topProcesses: [],
            disk: DiskUsage(totalBytes: 1000, availableBytes: 600),
            thermal: .nominal
        )
        #expect(report.warnings.isEmpty)
    }
}
