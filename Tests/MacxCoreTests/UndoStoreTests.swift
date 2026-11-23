import Foundation
import Testing
@testable import MacxCore

/// A throwaway folder per test, removed afterwards.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") throws -> URL {
        let f = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: f)
        return f
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }
}

@Suite("Undo store")
struct UndoStoreTests {
    @Test func stashMovesItemsOutAndRestorePutsThemBackIdentical() throws {
        let tmp = try TempDir()
        try tmp.file("home/Library/Caches/AppA/blob.bin", "hello cache")
        try tmp.file("home/Library/Caches/AppA/sub/deep.txt", "deep")
        try tmp.file("home/Library/Logs/app.log", "log line")
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))

        let batch = try store.stash(
            [tmp.url.appendingPathComponent("home/Library/Caches/AppA"),
             tmp.url.appendingPathComponent("home/Library/Logs/app.log")],
            reason: "test clean"
        )
        #expect(!tmp.exists("home/Library/Caches/AppA"))
        #expect(!tmp.exists("home/Library/Logs/app.log"))
        #expect(batch.items.count == 2)
        #expect(batch.totalBytes > 0)
        #expect(batch.reason == "test clean")

        let result = try store.restore(id: batch.id)
        #expect(result.restored.count == 2)
        #expect(result.skipped.isEmpty)
        #expect(try tmp.read("home/Library/Caches/AppA/blob.bin") == "hello cache")
        #expect(try tmp.read("home/Library/Caches/AppA/sub/deep.txt") == "deep")
        #expect(try tmp.read("home/Library/Logs/app.log") == "log line")
        #expect(try store.batches().isEmpty)
    }

    @Test func batchesSurviveANewStoreInstance() throws {
        let tmp = try TempDir()
        try tmp.file("a/one.txt")
        let root = tmp.url.appendingPathComponent("undo")
        let batch = try UndoStore(root: root).stash([tmp.url.appendingPathComponent("a/one.txt")], reason: "r")
        let listed = try UndoStore(root: root).batches()
        #expect(listed.map(\.id) == [batch.id])
        #expect(listed[0].items[0].originalPath == tmp.url.appendingPathComponent("a/one.txt").path)
    }

    @Test func restoreSkipsWhenSomethingNewIsAlreadyThere() throws {
        let tmp = try TempDir()
        try tmp.file("a/one.txt", "old")
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        let batch = try store.stash([tmp.url.appendingPathComponent("a/one.txt")], reason: "r")
        try tmp.file("a/one.txt", "new")

        let result = try store.restore(id: batch.id)
        #expect(result.restored.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(try tmp.read("a/one.txt") == "new")
        // The stashed copy is kept so nothing is lost.
        #expect(try store.batches().map(\.id) == [batch.id])
    }

    @Test func stashSkipsMissingPathsAndReportsThem() throws {
        let tmp = try TempDir()
        try tmp.file("a/real.txt")
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        let batch = try store.stash(
            [tmp.url.appendingPathComponent("a/real.txt"), tmp.url.appendingPathComponent("a/ghost.txt")],
            reason: "r"
        )
        #expect(batch.items.count == 1)
        #expect(batch.failed.count == 1)
    }

    @Test func emptyStashCreatesNoBatch() throws {
        let tmp = try TempDir()
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        #expect(throws: UndoError.nothingToStash) {
            try store.stash([tmp.url.appendingPathComponent("nope")], reason: "r")
        }
        #expect(try store.batches().isEmpty)
    }

    @Test func unknownIdThrows() throws {
        let tmp = try TempDir()
        let store = UndoStore(root: tmp.url.appendingPathComponent("undo"))
        #expect(throws: UndoError.unknownBatch("nope")) { try store.restore(id: "nope") }
    }

    @Test func purgeDeletesOnlyBatchesOlderThanTheLimit() throws {
        let tmp = try TempDir()
        try tmp.file("a/old.txt")
        try tmp.file("a/new.txt")
        let root = tmp.url.appendingPathComponent("undo")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try UndoStore(root: root, now: { start }).stash([tmp.url.appendingPathComponent("a/old.txt")], reason: "r")
        let new = try UndoStore(root: root, now: { start.addingTimeInterval(6 * 86400) })
            .stash([tmp.url.appendingPathComponent("a/new.txt")], reason: "r")

        let later = UndoStore(root: root, now: { start.addingTimeInterval(8 * 86400) })
        let purged = try later.purge(olderThan: 7 * 86400)
        #expect(purged.map(\.id) == [old.id])
        #expect(try later.batches().map(\.id) == [new.id])
    }

    @Test func sizeCountsNestedFiles() throws {
        let tmp = try TempDir()
        try tmp.file("d/a.txt", String(repeating: "a", count: 5000))
        try tmp.file("d/e/b.txt", String(repeating: "b", count: 5000))
        #expect(allocatedSize(of: tmp.url.appendingPathComponent("d")) >= 10000)
        #expect(allocatedSize(of: tmp.url.appendingPathComponent("missing")) == 0)
    }
}
