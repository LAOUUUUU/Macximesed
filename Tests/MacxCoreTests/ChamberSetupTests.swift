import Foundation
import Testing

@testable import MacxCore

/// Serves bytes by URL, like the CDN, and counts requests.
final class FakeDownloader: ChamberDownloading, @unchecked Sendable {
    var files: [String: Data] = [:]
    var requests: [String] = []
    func fetch(_ url: URL) throws -> Data {
        requests.append(url.absoluteString)
        guard let d = files[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return d
    }
}

@Suite("Light chamber setup")
struct ChamberSetupTests {
    /// A gzip'd tar of the given files, made with macOS's own tar (as Alpine's packages are).
    func tarGz(_ files: [String: String], in tmp: TempDir, name: String) throws -> Data {
        let dir = tmp.url.appendingPathComponent("src-\(name)")
        for (path, body) in files {
            let f = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: f)
        }
        let out = tmp.url.appendingPathComponent("\(name).tar.gz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", out.path, "-C", dir.path] + files.keys.sorted()
        try p.run()
        p.waitUntilExit()
        return try Data(contentsOf: out)
    }

    /// An EFI-zboot wrapper around gzip'd "kernel" bytes, laid out like Alpine's arm64 vmlinuz-virt.
    func zboot(_ raw: Data, in tmp: TempDir) throws -> Data {
        let src = tmp.url.appendingPathComponent("raw-kernel")
        try raw.write(to: src)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", src.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let gz = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var header = Data(count: 0x40)
        header[0] = 0x4D  // M
        header[1] = 0x5A  // Z
        header.replaceSubrange(4..<8, with: Array("zimg".utf8))
        withUnsafeBytes(of: UInt32(0x40).littleEndian) { header.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: UInt32(gz.count).littleEndian) { header.replaceSubrange(12..<16, with: $0) }
        header.replaceSubrange(0x18..<0x1C, with: Array("gzip".utf8))
        return header + gz
    }

    func fakeKernel() -> Data {
        var raw = Data(repeating: 0, count: 0x40)
        raw.replaceSubrange(0x38..<0x3C, with: Array("ARMd".utf8))
        return raw + Data("kernel body".utf8)
    }

    struct Fixture {
        var tmp: TempDir
        var downloader: FakeDownloader
        var manifest: ChamberManifest
        var store: ChamberStore
    }

    func fixture(corrupt: String? = nil) throws -> Fixture {
        let tmp = try TempDir()
        let rootfs = try tarGz(["bin/busybox": "busybox", "etc/os-release": "Alpine"], in: tmp, name: "rootfs")
        let bash = try tarGz([".PKGINFO": "pkgname = bash", "bin/bash": "bash binary"], in: tmp, name: "bash")
        // The kernel package holds a binary zboot file, so it's packed straight from disk.
        let kdir = tmp.url.appendingPathComponent("src-kernel/boot")
        try FileManager.default.createDirectory(at: kdir, withIntermediateDirectories: true)
        try zboot(fakeKernel(), in: tmp).write(to: kdir.appendingPathComponent("vmlinuz-virt"))
        let kout = tmp.url.appendingPathComponent("linux-virt.apk")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", kout.path, "-C", tmp.url.appendingPathComponent("src-kernel").path, "boot/vmlinuz-virt"]
        try p.run()
        p.waitUntilExit()
        let kernelPkg = try Data(contentsOf: kout)

        let d = FakeDownloader()
        func entry(_ role: String, _ name: String, _ data: Data) -> ChamberManifest.File {
            let url = "https://cdn.example.invalid/\(name)"
            d.files[url] = corrupt == name ? data + Data([0]) : data
            return ChamberManifest.File(role: role, name: name, version: "1", url: url, sha256: sha256(data), bytes: data.count)
        }
        let manifest = ChamberManifest(
            schema: 1, alpine: "3.24.4", arch: "aarch64",
            files: [entry("rootfs", "alpine-minirootfs", rootfs), entry("kernel", "linux-virt", kernelPkg), entry("package", "bash", bash)])
        return Fixture(tmp: tmp, downloader: d, manifest: manifest, store: ChamberStore(root: tmp.url.appendingPathComponent("Chamber")))
    }

    @Test func installsRootfsPackagesAndKernel() throws {
        let f = try fixture()
        let setup = ChamberSetup(manifest: f.manifest, store: f.store, downloader: f.downloader, freeBytes: { 10_000_000_000 })
        #expect(!f.store.isInstalled(for: f.manifest))
        try setup.run()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: f.store.rootfs.appendingPathComponent("bin/busybox").path))
        #expect(fm.fileExists(atPath: f.store.rootfs.appendingPathComponent("bin/bash").path))
        // Package metadata never lands in the rootfs.
        #expect(!fm.fileExists(atPath: f.store.rootfs.appendingPathComponent(".PKGINFO").path))
        // The kernel is unwrapped to the raw arm64 Image.
        #expect(try Data(contentsOf: f.store.kernel) == fakeKernel())
        #expect(f.store.isInstalled(for: f.manifest))
        // Downloads are removed afterwards; only the chamber stays.
        #expect(!fm.fileExists(atPath: f.store.root.appendingPathComponent("downloads").path))
    }

    @Test func refusesAFileWhoseHashDoesNotMatch() throws {
        let f = try fixture(corrupt: "bash")
        let setup = ChamberSetup(manifest: f.manifest, store: f.store, downloader: f.downloader, freeBytes: { 10_000_000_000 })
        #expect(throws: ChamberSetup.Problem.hashMismatch("bash")) { try setup.run() }
        #expect(!f.store.isInstalled(for: f.manifest))
    }

    @Test func intelKernelIsCheckedToo() throws {
        // An arm64 zboot kernel in an x86_64 manifest isn't a bzImage: setup refuses it instead of installing it unchecked.
        var f = try fixture()
        f.manifest.arch = "x86_64"
        let setup = ChamberSetup(manifest: f.manifest, store: f.store, downloader: f.downloader, freeBytes: { 10_000_000_000 })
        #expect(throws: ChamberSetup.Problem.self) { try setup.run() }
        #expect(!f.store.isInstalled(for: f.manifest))
    }

    @Test func refusesWithoutEnoughDiskSpace() throws {
        let f = try fixture()
        let setup = ChamberSetup(manifest: f.manifest, store: f.store, downloader: f.downloader, freeBytes: { 1000 })
        #expect(throws: ChamberSetup.Problem.self) { try setup.run() }
        #expect(f.downloader.requests.isEmpty)
    }

    @Test func planShowsFilesAndTotal() throws {
        let f = try fixture()
        let plan = ChamberSetup(manifest: f.manifest, store: f.store, downloader: f.downloader, freeBytes: { 5 }).plan()
        #expect(plan.files.count == 3)
        #expect(plan.downloadBytes == f.manifest.files.reduce(0) { $0 + $1.bytes })
        #expect(plan.freeBytes == 5)
    }

    @Test func bundledManifestIsPinnedAndHasAKernel() throws {
        let m = try ChamberManifest.bundled(arch: "aarch64")
        #expect(m.files.contains { $0.role == "kernel" && $0.name == "linux-virt" })
        #expect(m.files.contains { $0.role == "rootfs" })
        #expect(m.files.allSatisfy { $0.sha256.count == 64 && $0.url.hasPrefix("https://dl-cdn.alpinelinux.org/") })
        #expect(throws: (any Error).self) { try ChamberManifest.bundled(arch: "sparc") }
    }
}
