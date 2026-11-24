import Foundation
import Testing

@testable import MacxCore

/// The light chamber boots from an initramfs that macx builds per run, in the "newc" cpio format Linux reads.
@Suite("Light chamber: initramfs (cpio newc)")
struct CPIOTests {
    func sample() -> CPIOArchive {
        var a = CPIOArchive()
        a.addDirectory("Users/chamber/Downloads")
        a.addFile("Users/chamber/Downloads/installer.sh", data: Data("echo hi\n".utf8), mode: 0o755)
        a.addFile("init", data: Data("#!/bin/sh\nexec /sbin/agent\n".utf8), mode: 0o755)
        a.addSymlink("bin/sh", target: "/bin/busybox")
        return a
    }

    @Test func macOSCpioCanListIt() throws {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("initramfs.cpio")
        try sample().data().write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/cpio")
        p.arguments = ["-it"]
        p.standardInput = try FileHandle(forReadingFrom: file)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let listed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(p.terminationStatus == 0)
        // Parent folders are added automatically, before their contents.
        #expect(listed.contains("Users"))
        #expect(listed.contains("Users/chamber/Downloads/installer.sh"))
        #expect(listed.contains("init"))
        #expect(listed.contains("bin/sh"))
        #expect(listed.firstIndex(of: "Users")! < listed.firstIndex(of: "Users/chamber/Downloads/installer.sh")!)
    }

    @Test func entriesReadBackExactly() throws {
        let entries = try CPIOReader.entries(sample().data())
        let script = try #require(entries.first { $0.name == "Users/chamber/Downloads/installer.sh" })
        #expect(script.data == Data("echo hi\n".utf8))
        #expect(script.mode & 0o777 == 0o755)
        #expect(script.mode & 0o170000 == 0o100000)  // regular file
        let link = try #require(entries.first { $0.name == "bin/sh" })
        #expect(link.mode & 0o170000 == 0o120000)  // symlink
        #expect(link.data == Data("/bin/busybox".utf8))
        #expect(entries.last?.name == "TRAILER!!!")
    }

    @Test func refusesEscapingPaths() {
        var a = CPIOArchive()
        #expect(throws: CPIOArchive.Problem.badPath) { try a.add(path: "../etc/passwd", kind: .file(Data()), mode: 0o644) }
        #expect(throws: CPIOArchive.Problem.badPath) { try a.add(path: "a/../../b", kind: .file(Data()), mode: 0o644) }
    }

    @Test func laterEntriesReplaceEarlierOnes() throws {
        var a = CPIOArchive()
        a.addFile("etc/hostname", data: Data("one".utf8))
        a.addFile("etc/hostname", data: Data("two".utf8))
        let entries = try CPIOReader.entries(a.data())
        #expect(entries.filter { $0.name == "etc/hostname" }.map(\.data) == [Data("two".utf8)])
    }
}

/// A minimal newc reader for the tests.
enum CPIOReader {
    struct Entry {
        var name: String
        var mode: UInt32
        var data: Data
    }

    static func entries(_ d: Data) throws -> [Entry] {
        var out: [Entry] = []
        var i = d.startIndex
        func pad(_ n: Int) -> Int { (4 - n % 4) % 4 }
        while i + 110 <= d.endIndex {
            let header = String(decoding: d[i..<i + 110], as: UTF8.self)
            guard header.hasPrefix("070701") else { throw CocoaError(.fileReadCorruptFile) }
            func field(_ n: Int) -> Int { Int(header.dropFirst(6 + n * 8).prefix(8), radix: 16) ?? 0 }
            let mode = UInt32(field(1))
            let size = field(6)
            let nameSize = field(11)
            let nameStart = i + 110
            let name = String(decoding: d[nameStart..<nameStart + nameSize - 1], as: UTF8.self)
            let dataStart = nameStart + nameSize + pad(110 + nameSize)
            out.append(Entry(name: name, mode: mode, data: d[dataStart..<dataStart + size]))
            i = dataStart + size + pad(size)
            if name == "TRAILER!!!" { break }
        }
        return out
    }
}
