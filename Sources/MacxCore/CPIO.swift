import Foundation

/// Builds an initramfs in the "newc" cpio format the Linux kernel unpacks at boot. The light chamber makes a
/// fresh one per run: the Alpine base, the stand-in Mac commands, the agent and the pinned sample.
public struct CPIOArchive: Sendable {
    public enum Problem: Error, Equatable { case badPath }

    public enum Kind: Sendable {
        case directory
        case file(Data)
        case symlink(String)
    }

    struct Entry: Sendable {
        var path: String
        var kind: Kind
        var mode: UInt32
    }

    var entries: [Entry] = []
    var index: [String: Int] = [:]

    public init() {}

    /// Adds an entry, with any missing parent folders first. A later entry for the same path replaces the earlier one.
    public mutating func add(path: String, kind: Kind, mode: UInt32) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { throw Problem.badPath }
        for n in 1..<parts.count {
            let dir = parts.prefix(n).joined(separator: "/")
            if index[dir] == nil { put(Entry(path: dir, kind: .directory, mode: 0o755)) }
        }
        put(Entry(path: parts.joined(separator: "/"), kind: kind, mode: mode))
    }

    mutating func put(_ e: Entry) {
        if let i = index[e.path] {
            entries[i] = e
        } else {
            index[e.path] = entries.count
            entries.append(e)
        }
    }

    public mutating func addDirectory(_ path: String, mode: UInt32 = 0o755) { try? add(path: path, kind: .directory, mode: mode) }
    public mutating func addFile(_ path: String, data: Data, mode: UInt32 = 0o644) { try? add(path: path, kind: .file(data), mode: mode) }
    public mutating func addSymlink(_ path: String, target: String) { try? add(path: path, kind: .symlink(target), mode: 0o777) }

    public func data() -> Data {
        var out = Data()
        var ino: UInt32 = 1
        func pad(_ count: Int) { out.append(contentsOf: [UInt8](repeating: 0, count: (4 - count % 4) % 4)) }
        func write(_ name: String, mode: UInt32, body: Data, nlink: UInt32) {
            let nameBytes = Array(name.utf8) + [0]
            let fields: [UInt32] = [
                ino, mode, 0, 0, nlink, 0, UInt32(body.count), 0, 0, 0, 0, UInt32(nameBytes.count), 0,
            ]
            out.append(contentsOf: Array("070701".utf8))
            for f in fields { out.append(contentsOf: Array(String(format: "%08X", f).utf8)) }
            out.append(contentsOf: nameBytes)
            pad(110 + nameBytes.count)
            out.append(body)
            pad(body.count)
            ino += 1
        }
        for e in entries {
            switch e.kind {
            case .directory: write(e.path, mode: 0o040000 | e.mode, body: Data(), nlink: 2)
            case .file(let d): write(e.path, mode: 0o100000 | e.mode, body: d, nlink: 1)
            case .symlink(let t): write(e.path, mode: 0o120000 | 0o777, body: Data(t.utf8), nlink: 1)
            }
        }
        write("TRAILER!!!", mode: 0, body: Data(), nlink: 1)
        return out
    }
}
