import Darwin
import Foundation
import Testing

@testable import MacxCore

func residentMB() -> Int {
    var info = mach_task_basic_info()
    var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) }
    }
    return Int(info.resident_size / 1_000_000)
}

@Suite("Reading eslogger's output", .serialized)
struct LineReaderTests {
    func pipe(_ script: String) throws -> (Process, FileHandle) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        return (p, out.fileHandleForReading)
    }

    @Test func splitsLinesAcrossChunks() throws {
        let (p, h) = try pipe("printf 'one\\ntw'; sleep 0.1; printf 'o\\n\\nthree'")
        var lines: [String] = []
        LineReader.forEachLine(h) { lines.append($0) }
        p.waitUntilExit()
        #expect(lines == ["one", "two", "", "three"])
    }

    @Test func memoryStaysFlatOverHoursOfEvents() throws {
        // The watch reads eslogger for days. Without a pool per chunk every chunk stayed in memory (370 MB in the eval).
        let line = #"{"event":{"exec":{}},"process":{"executable":{"path":"/bin/zsh"}}}"#
        let (p, h) = try pipe("yes '\(line)' | head -c 200000000")
        let before = residentMB()
        var count = 0
        LineReader.forEachLine(h) { _ in count += 1 }
        p.waitUntilExit()
        #expect(count > 2_000_000)
        #expect(residentMB() - before < 60)
    }

    @Test func hashingABigFileDoesntKeepIt() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("big")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let w = try FileHandle(forWritingTo: file)
        let mb = Data(repeating: 7, count: 1 << 20)
        for _ in 0..<200 { w.write(mb) }
        try w.close()
        let before = residentMB()
        #expect(FileChecker.hashFile(file) != nil)
        #expect(residentMB() - before < 60)
    }
}
