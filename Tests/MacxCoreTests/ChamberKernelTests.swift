import Foundation
import Testing

@testable import MacxCore

/// `VZLinuxBootLoader` wants a raw arm64 `Image` on Apple silicon and a bzImage on Intel. Alpine ships the arm64
/// kernel wrapped in EFI-zboot (gzip inside), so it has to be unwrapped first. Small synthetic kernels stand in for
/// the real 10 MB files.
@Suite("Light chamber: kernel for VZLinuxBootLoader")
struct ChamberKernelTests {
    /// A fake raw arm64 Image: 64-byte header with "ARM\x64" at 0x38, then some body.
    func fakeArm64Image(body: Int = 3000) -> Data {
        var d = Data(count: 64)
        d.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
        d.append(Data((0..<body).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        return d
    }

    func gzip(_ data: Data) throws -> Data {
        let tmp = try TempDir()
        let file = tmp.url.appendingPathComponent("k")
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", "-n", file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let gz = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return gz
    }

    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// The EFI-zboot layout from drivers/firmware/efi/libstub/zboot-header.S: "MZ", "zimg" at 4, payload offset
    /// and size at 8 and 12, the compression name at 24, and the compressed payload further in.
    func zboot(_ payload: Data, compression: String = "gzip", offset: Int = 256) -> Data {
        var d = Data(count: offset)
        d.replaceSubrange(0..<2, with: Array("MZ".utf8))
        d.replaceSubrange(4..<8, with: Array("zimg".utf8))
        d.replaceSubrange(8..<12, with: le32(offset))
        d.replaceSubrange(12..<16, with: le32(payload.count))
        d.replaceSubrange(24..<(24 + compression.utf8.count), with: Array(compression.utf8))
        d.append(payload)
        d.append(Data(repeating: 0xEE, count: 64))  // the EFI stub's code after the payload
        return d
    }

    /// A fake bzImage: boot sector signature, "HdrS", boot protocol version and loadflags.
    func fakeBzImage(version: UInt16 = 0x020F, loadflags: UInt8 = 0x01) -> Data {
        var d = Data(count: 0x1000)
        d[0x1FE] = 0x55
        d[0x1FF] = 0xAA
        d.replaceSubrange(0x202..<0x206, with: Array("HdrS".utf8))
        d[0x206] = UInt8(version & 0xFF)
        d[0x207] = UInt8(version >> 8)
        d[0x211] = loadflags
        return d
    }

    @Test func unwrapsZbootGzipToRawArm64Image() throws {
        let image = fakeArm64Image()
        let out = try ChamberKernel.prepare(zboot(gzip(image)), arch: "aarch64")
        #expect(out == image)
    }

    @Test func rawArm64ImagePassesThrough() throws {
        let image = fakeArm64Image()
        #expect(try ChamberKernel.prepare(image, arch: "aarch64") == image)
    }

    @Test func plainGzipArm64ImageIsDecompressed() throws {
        let image = fakeArm64Image()
        #expect(try ChamberKernel.prepare(gzip(image), arch: "aarch64") == image)
    }

    @Test func zbootWithOtherCompressionIsRefused() throws {
        #expect(throws: ChamberKernel.Problem.unsupportedCompression("zstd")) {
            try ChamberKernel.prepare(zboot(Data(count: 100), compression: "zstd"), arch: "aarch64")
        }
    }

    @Test func zbootPayloadOutsideTheFileIsRefused() throws {
        var d = zboot(Data(count: 100))
        d.replaceSubrange(12..<16, with: le32(1_000_000))
        #expect(throws: ChamberKernel.Problem.truncated) { try ChamberKernel.prepare(d, arch: "aarch64") }
    }

    @Test func zbootWhoseContentIsNotArm64IsRefused() throws {
        let notArm = Data(repeating: 7, count: 500)
        #expect(throws: ChamberKernel.Problem.notArm64Image) {
            try ChamberKernel.prepare(zboot(gzip(notArm)), arch: "aarch64")
        }
    }

    @Test func corruptGzipIsRefused() throws {
        var gz = try gzip(fakeArm64Image())
        gz.replaceSubrange(20..<40, with: Data(repeating: 0xFF, count: 20))
        #expect(throws: ChamberKernel.Problem.badGzip) { try ChamberKernel.prepare(zboot(gz), arch: "aarch64") }
    }

    @Test func bzImagePassesThroughUnchanged() throws {
        let bz = fakeBzImage()
        #expect(try ChamberKernel.prepare(bz, arch: "x86_64") == bz)
    }

    @Test func bzImageWithEfiStubHeaderIsStillABzImage() throws {
        var bz = fakeBzImage()
        bz.replaceSubrange(0..<2, with: Array("MZ".utf8))  // EFI_STUB kernels start with a PE header
        #expect(try ChamberKernel.prepare(bz, arch: "x86_64") == bz)
    }

    @Test func oldBootProtocolIsRefused() throws {
        #expect(throws: ChamberKernel.Problem.oldBootProtocol(0x0203)) {
            try ChamberKernel.prepare(fakeBzImage(version: 0x0203), arch: "x86_64")
        }
    }

    @Test func zImageWithoutLoadedHighIsRefused() throws {
        #expect(throws: ChamberKernel.Problem.notBzImage) {
            try ChamberKernel.prepare(fakeBzImage(loadflags: 0), arch: "x86_64")
        }
    }

    @Test func elfVmlinuxIsRefusedOnIntel() throws {
        var elf = Data([0x7F, 0x45, 0x4C, 0x46])
        elf.append(Data(count: 0x1000))
        #expect(throws: ChamberKernel.Problem.unknownFormat) { try ChamberKernel.prepare(elf, arch: "x86_64") }
    }

    @Test func arm64KernelOnIntelIsRefused() throws {
        #expect(throws: ChamberKernel.Problem.unknownFormat) {
            try ChamberKernel.prepare(fakeArm64Image(), arch: "x86_64")
        }
    }

    @Test func tinyInputIsRefused() throws {
        #expect(throws: ChamberKernel.Problem.unknownFormat) { try ChamberKernel.prepare(Data(), arch: "aarch64") }
        #expect(throws: ChamberKernel.Problem.unknownFormat) { try ChamberKernel.prepare(Data([1, 2]), arch: "x86_64") }
    }

    @Test func unknownArchIsRefused() throws {
        #expect(throws: ChamberKernel.Problem.unknownArch("riscv64")) {
            try ChamberKernel.prepare(fakeArm64Image(), arch: "riscv64")
        }
    }
}

/// The pinned manifests macx carries: one per Mac architecture, each with exactly one kernel and only Alpine URLs.
@Suite("Light chamber: pinned manifests")
struct ChamberManifestDataTests {
    @Test(arguments: ["aarch64", "x86_64"]) func manifestIsPinnedAndWellFormed(arch: String) throws {
        let text = try #require(ChamberManifestData.json[arch])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(obj["arch"] as? String == arch)
        let files = try #require(obj["files"] as? [[String: Any]])
        #expect(files.filter { $0["role"] as? String == "kernel" }.count == 1)
        #expect(files.filter { $0["role"] as? String == "rootfs" }.count == 1)
        for f in files {
            let url = try #require(f["url"] as? String)
            #expect(url.hasPrefix("https://dl-cdn.alpinelinux.org/alpine/v3.24/"))
            #expect(url.contains("/\(arch)/"))
            let sha = try #require(f["sha256"] as? String)
            #expect(sha.count == 64 && sha.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect((f["bytes"] as? Int ?? 0) > 0)
        }
    }
}
