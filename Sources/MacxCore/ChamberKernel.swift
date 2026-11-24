import Foundation

/// Turns the kernel from Alpine's `linux-virt` package into what `VZLinuxBootLoader` boots.
///
/// - **aarch64:** the framework wants a raw arm64 `Image` (magic "ARM\x64" at 0x38). Alpine's `vmlinuz-virt` is
///   EFI-zboot: a small PE stub ("MZ", "zimg" at 4) with a gzip payload whose offset and size sit at bytes 8 and 12.
///   That payload is unwrapped here. A plain gzip file or an already raw `Image` is accepted too.
/// - **x86_64:** the framework uses the x86 boot protocol, so the kernel is a bzImage (0xAA55 at 0x1FE, "HdrS" at
///   0x202, protocol 2.04 or later, loaded high). It's checked and returned unchanged. An ELF `vmlinux` is refused.
///
/// The input is a pinned file (SHA-256 from the manifest), but it's still parsed defensively: every offset is
/// bounds-checked and the gzip CRC and length are verified.
public enum ChamberKernel {
    public enum Problem: Error, Equatable {
        case unknownArch(String)
        case unknownFormat
        case unsupportedCompression(String)
        case truncated
        case badGzip
        case notArm64Image
        case oldBootProtocol(UInt16)
        case notBzImage
    }

    public static func prepare(_ data: Data, arch: String) throws -> Data {
        let bytes = [UInt8](data)
        switch arch {
        case "aarch64", "arm64": return try arm64(bytes)
        case "x86_64", "amd64": return try x86(bytes)
        default: throw Problem.unknownArch(arch)
        }
    }

    // MARK: arm64

    static func arm64(_ b: [UInt8]) throws -> Data {
        if isArm64Image(b) { return Data(b) }
        let image: [UInt8]
        if b.count >= 64, b[0] == 0x4D, b[1] == 0x5A, Array(b[4..<8]) == Array("zimg".utf8) {
            let offset = Int(le32(b, 8))
            let size = Int(le32(b, 12))
            let name = String(decoding: b[24..<56].prefix { $0 != 0 }, as: UTF8.self)
            guard name == "gzip" else { throw Problem.unsupportedCompression(name) }
            guard offset >= 64, size > 0, offset <= b.count, size <= b.count - offset else { throw Problem.truncated }
            image = try gunzip(Array(b[offset..<(offset + size)]))
        } else if b.count >= 2, b[0] == 0x1F, b[1] == 0x8B {
            image = try gunzip(b)
        } else {
            throw Problem.unknownFormat
        }
        guard isArm64Image(image) else { throw Problem.notArm64Image }
        return Data(image)
    }

    static func isArm64Image(_ b: [UInt8]) -> Bool {
        b.count >= 64 && Array(b[0x38..<0x3C]) == [0x41, 0x52, 0x4D, 0x64]
    }

    // MARK: x86_64

    static func x86(_ b: [UInt8]) throws -> Data {
        guard b.count >= 0x400, b[0x1FE] == 0x55, b[0x1FF] == 0xAA, Array(b[0x202..<0x206]) == Array("HdrS".utf8)
        else { throw Problem.unknownFormat }
        let version = UInt16(b[0x206]) | UInt16(b[0x207]) << 8
        guard version >= 0x0204 else { throw Problem.oldBootProtocol(version) }
        guard b[0x211] & 0x01 != 0 else { throw Problem.notBzImage }  // LOADED_HIGH: a bzImage, not an old zImage
        return Data(b)
    }

    // MARK: gzip (RFC 1952)

    /// Decompresses one gzip member. The header is parsed here and the deflate body goes to Foundation's zlib
    /// decoder (raw deflate); the CRC-32 and length in the trailer must match.
    static func gunzip(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw Problem.badGzip }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard i + 2 <= b.count else { throw Problem.badGzip }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {  // FNAME, FCOMMENT: zero-terminated
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }  // FHCRC
        guard i <= b.count - 8 else { throw Problem.badGzip }
        let crc = le32(b, b.count - 8)
        let length = le32(b, b.count - 4)
        let body = Data(b[i..<(b.count - 8)])
        guard let out = try? (body as NSData).decompressed(using: .zlib) as Data else { throw Problem.badGzip }
        let result = [UInt8](out)
        guard UInt32(truncatingIfNeeded: result.count) == length, crc32(result) == crc else { throw Problem.badGzip }
        return result
    }

    static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in b { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
