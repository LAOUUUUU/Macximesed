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
    /// Decimal units (1 KB = 1000 bytes), as Finder and About This Mac count them. The CLI and the app both print
    /// sizes with this, so `macx undo` and the app's Clean page show the same figure.
    @Test func formatsInDecimalUnitsLikeFinder() {
        #expect(formatBytes(0) == "0 B")
        #expect(formatBytes(512) == "512 B")
        #expect(formatBytes(999) == "999 B")
        #expect(formatBytes(1000) == "1.0 KB")
        #expect(formatBytes(1536) == "1.5 KB")
        #expect(formatBytes(2_500_000) == "2.5 MB")
        #expect(formatBytes(5_000_000_000) == "5.0 GB")
        // 5 GiB: binary units called this 5.0 GB, Finder calls it 5.4 GB.
        #expect(formatBytes(5 * 1024 * 1024 * 1024) == "5.4 GB")
        #expect(formatBytes(2_000_000_000_000) == "2.0 TB")
    }

    @Test func roundsUpIntoTheNextUnit() {
        #expect(formatBytes(999_960) == "1.0 MB")  // not "1000.0 KB"
        #expect(formatBytes(999_940) == "999.9 KB")
    }

    /// Memory in binary units (1 KB = 1024 bytes), as Activity Monitor, `top` and About This Mac's "16 GB" count RAM.
    @Test func memoryIsInBinaryUnitsLikeActivityMonitor() {
        #expect(formatMemory(17_179_869_184) == "16.0 GB")  // a 16 GB Mac
        #expect(formatMemory(512) == "512 B")
        #expect(formatMemory(1023) == "1023 B")
        #expect(formatMemory(1024) == "1.0 KB")
        #expect(formatMemory(1536) == "1.5 KB")
        #expect(formatMemory(150 * 1024 * 1024) == "150.0 MB")
        #expect(formatMemory(1_048_570) == "1.0 MB")  // 1023.99 KB rounds up into MB, not "1024.0 KB"
        #expect(formatMemory(1_048_500) == "1023.9 KB")
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

    @Test func processMemoryIsBinaryAndDiskIsDecimal() {
        let report = ScanReport(
            protections: Protections(sip: .on, gatekeeper: .on, fileVault: .on, firewall: .on),
            topProcesses: [ProcessSample(pid: 5, cpuPercent: 1, memoryBytes: 150 * 1024 * 1024, path: "/usr/bin/hog")],
            disk: DiskUsage(totalBytes: 500_000_000_000, availableBytes: 100_000_000_000),
            thermal: .nominal
        )
        let text = report.render()
        #expect(text.contains("150.0 MB"))  // what Activity Monitor shows; decimal would read 157.3 MB
        #expect(text.contains("100.0 GB free of 500.0 GB"))  // what Finder shows
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
