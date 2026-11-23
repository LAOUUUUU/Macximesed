import Foundation

public enum UndoError: Error, Equatable {
    case nothingToStash
    case unknownBatch(String)
}

public struct UndoItem: Codable, Sendable, Equatable {
    public var originalPath: String
    public var storedName: String
    public var bytes: UInt64
}

public struct UndoBatch: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var reason: String
    public var items: [UndoItem]
    /// Paths that could not be moved (missing, or permission denied). Not saved in the manifest.
    public var failed: [String] = []

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    enum CodingKeys: String, CodingKey { case id, createdAt, reason, items }
}

public struct RestoreResult: Sendable, Equatable {
    public var restored: [String]
    /// Originals that already exist again, so the stashed copy was kept instead of overwriting.
    public var skipped: [String]
}

/// Moves files into a dated holding folder instead of deleting them, so every cleanup can be undone.
///
/// Layout: `<root>/<batch id>/manifest.json` plus `<root>/<batch id>/items/<n>-<name>`.
/// The default root sits on the same volume as the home folder, so a stash is a rename, not a copy.
public struct UndoStore: Sendable {
    public let root: URL
    let now: @Sendable () -> Date

    public init(root: URL = UndoStore.defaultRoot, now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Macximesed/Undo", isDirectory: true)
    }

    @discardableResult
    public func stash(_ paths: [URL], reason: String) throws -> UndoBatch {
        let fm = FileManager.default
        let created = now()
        let id = Self.makeID(created)
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let itemsDir = dir.appendingPathComponent("items", isDirectory: true)
        try fm.createDirectory(at: itemsDir, withIntermediateDirectories: true)

        var batch = UndoBatch(id: id, createdAt: created, reason: reason, items: [])
        for (index, path) in paths.enumerated() {
            guard fm.fileExists(atPath: path.path) else {
                batch.failed.append(path.path)
                continue
            }
            let stored = "\(index)-\(path.lastPathComponent)"
            let bytes = allocatedSize(of: path)
            do {
                try fm.moveItem(at: path, to: itemsDir.appendingPathComponent(stored))
                batch.items.append(UndoItem(originalPath: path.path, storedName: stored, bytes: bytes))
            } catch {
                batch.failed.append(path.path)
            }
        }

        guard !batch.items.isEmpty else {
            try? fm.removeItem(at: dir)
            throw UndoError.nothingToStash
        }
        try write(batch, to: dir)
        return batch
    }

    public func batches() throws -> [UndoBatch] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { try? read(root.appendingPathComponent($0, isDirectory: true)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func restore(id: String) throws -> RestoreResult {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(id, isDirectory: true)
        guard var batch = try? read(dir) else { throw UndoError.unknownBatch(id) }
        let itemsDir = dir.appendingPathComponent("items", isDirectory: true)

        var result = RestoreResult(restored: [], skipped: [])
        var remaining: [UndoItem] = []
        for item in batch.items {
            let original = URL(fileURLWithPath: item.originalPath)
            if fm.fileExists(atPath: original.path) {
                result.skipped.append(item.originalPath)
                remaining.append(item)
                continue
            }
            do {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: itemsDir.appendingPathComponent(item.storedName), to: original)
                result.restored.append(item.originalPath)
            } catch {
                result.skipped.append(item.originalPath)
                remaining.append(item)
            }
        }

        if remaining.isEmpty {
            try fm.removeItem(at: dir)
        } else {
            batch.items = remaining
            try write(batch, to: dir)
        }
        return result
    }

    /// Permanently deletes batches older than `age` seconds. This is the only place anything is really deleted.
    @discardableResult
    public func purge(olderThan age: TimeInterval) throws -> [UndoBatch] {
        let cutoff = now().addingTimeInterval(-age)
        let old = try batches().filter { $0.createdAt < cutoff }
        for batch in old {
            try FileManager.default.removeItem(at: root.appendingPathComponent(batch.id, isDirectory: true))
        }
        return old
    }

    // MARK: - Manifest

    private func write(_ batch: UndoBatch, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batch).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func read(_ dir: URL) throws -> UndoBatch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UndoBatch.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
    }

    static func makeID(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: date))-\(UUID().uuidString.prefix(6).lowercased())"
    }
}

/// Space a file or folder takes on disk. Missing paths count as zero.
public func allocatedSize(of url: URL) -> UInt64 {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
    guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
    if values.isDirectory != true {
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else {
        return 0
    }
    var total: UInt64 = 0
    for case let child as URL in walker {
        if let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true {
            total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
    }
    return total
}
