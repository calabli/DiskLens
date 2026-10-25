import Foundation
import Testing
@testable import DiskLensCore

/// A sandbox folder whose contents tests change between scans.
private final class Folder {
    let root: String

    init() throws {
        // realpath, so paths match what FSEvents reports (/private/var, not /var).
        let base = NSTemporaryDirectory() + "disklens-history-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ relative: String, bytes: Int) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: root + "/" + relative)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func scan() throws -> FileTree { try DiskScanner().scan(root) }

    func populate() throws {
        try write("a/one.bin", bytes: 20_000)
        try write("a/b/two.bin", bytes: 40_000)
        try write("c/three.bin", bytes: 60_000)
        try write("c/deep/er/four.bin", bytes: 10_000)
        try write("keep/five.bin", bytes: 30_000)
    }

    /// Adds, grows, deletes and creates, touching `a`, `a/b`, the root and `new`.
    func change() throws {
        try write("a/one.bin", bytes: 120_000)
        try write("a/b/added.bin", bytes: 50_000)
        try remove("c")
        try write("new/x/y/six.bin", bytes: 70_000)
    }
}

/// Every path in `tree` with its total size.
private func sizesByPath(_ tree: FileTree) -> [String: Int64] {
    var result: [String: Int64] = [:]
    var stack = [0]
    while let node = stack.popLast() {
        result[tree.path(of: node)] = tree.totalSizes[node]
        stack.append(contentsOf: tree.children(of: node).map(Int.init))
    }
    return result
}

@Test func cachedScansRoundTrip() throws {
    let folder = try Folder()
    try folder.populate()
    var tree = try folder.scan()
    tree.remove(try #require(tree.node(atPath: folder.path("keep/five.bin"))))
    let cache = ScanCache(directory: URL(fileURLWithPath: folder.root + "-cache"))
    defer { try? FileManager.default.removeItem(at: cache.directory) }

    try cache.save(CachedScan(tree: tree, scannedAt: Date(timeIntervalSince1970: 1_000), eventID: 42,
                              journalID: "journal"))
    let loaded = try #require(cache.load(rootPath: folder.root))

    #expect(loaded.eventID == 42 && loaded.journalID == "journal")
    #expect(loaded.scannedAt == Date(timeIntervalSince1970: 1_000))
    #expect(sizesByPath(loaded.tree) == sizesByPath(tree))  // the removed file stays removed
    #expect(loaded.tree.stats.files == tree.stats.files)
    #expect(cache.load(rootPath: folder.root + "/a") == nil)
}

@Test func updatingTheChangedFoldersMatchesAFreshScan() throws {
    let folder = try Folder()
    try folder.populate()
    let before = try folder.scan()
    try folder.change()

    let changes = ChangeSet(folders: [folder.root, folder.path("a"), folder.path("a/b")])
    let updated = try TreeUpdater.update(before, applying: changes)

    #expect(sizesByPath(updated) == sizesByPath(try folder.scan()))
    #expect(updated.node(atPath: folder.path("c")) == nil)
    #expect(updated.node(atPath: folder.path("new/x/y/six.bin")) != nil)
}

@Test func lostDetailRescansTheWholeSubtree() throws {
    let folder = try Folder()
    try folder.populate()
    let before = try folder.scan()
    try folder.write("a/b/c/d/deeper.bin", bytes: 30_000)

    let updated = try TreeUpdater.update(before, applying: ChangeSet(subtrees: [folder.path("a")]))

    #expect(sizesByPath(updated) == sizesByPath(try folder.scan()))
}

@Test func noChangesKeepsTheTreeAsItWas() throws {
    let folder = try Folder()
    try folder.populate()
    let before = try folder.scan()

    let updated = try TreeUpdater.update(before, applying: ChangeSet())

    #expect(sizesByPath(updated) == sizesByPath(before))
}

@Test func theJournalReportsChangedFolders() async throws {
    let folder = try Folder()
    try folder.populate()
    let since = ChangeJournal.currentEventID()
    try folder.change()

    // The journal records changes asynchronously; give it a few seconds.
    var changes: ChangeSet?
    for _ in 0..<30 {
        changes = ChangeJournal.changes(under: folder.root, since: since)
        if let changes, changes.folders.contains(folder.path("a/b")), changes.folders.contains(folder.path("new/x/y")) {
            break
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    let found = try #require(changes)
    #expect(found.folders.contains(folder.path("a")))
    #expect(found.folders.contains(folder.path("a/b")))
    #expect(found.folders.allSatisfy { $0 == folder.root || $0.hasPrefix(folder.root + "/") })
    #expect(ChangeJournal.journalID(for: folder.root) != nil)
}

@Test func comparisonPointsAtTheMostSpecificChanges() throws {
    let folder = try Folder()
    try folder.populate()
    try folder.write("media/movies/old.mov", bytes: 300_000)
    let before = try folder.scan()
    try folder.write("media/movies/new.mov", bytes: 500_000)   // growth, all in one file
    try folder.remove("c")                                      // shrink
    let after = try folder.scan()

    let comparison = ScanComparison(previous: before, previousDate: Date(), current: after,
                                    minimumChange: 40_000)

    #expect(comparison.delta == after.totalSize - before.totalSize)
    let paths = comparison.changes.map(\.path)
    #expect(paths.first == folder.path("media/movies/new.mov"))
    #expect(paths.contains(folder.path("c")))
    // Explained by the file, so the folders above it are not listed separately.
    #expect(!paths.contains(folder.path("media")) && !paths.contains(folder.path("media/movies")))
    let removed = try #require(comparison.changes.first { $0.path == folder.path("c") })
    #expect(removed.after == 0 && removed.before > 0)
    // A folder that vanished as a whole is listed as the folder, not as its files.
    #expect(!paths.contains(folder.path("c/three.bin")))
}

@Test func historyKeepsTheLatestEntries() throws {
    let folder = try Folder()
    try folder.populate()
    let tree = try folder.scan()
    let history = ScanHistory(directory: URL(fileURLWithPath: folder.root + "-history"))
    defer { try? FileManager.default.removeItem(at: history.url.deletingLastPathComponent()) }

    for day in 0..<5 {
        try history.record(tree, at: Date(timeIntervalSince1970: Double(day) * 86_400), limit: 3)
    }

    let entries = history.entries()
    #expect(entries.count == 3)
    #expect(entries.last?.date == Date(timeIntervalSince1970: 4 * 86_400))
    #expect(entries.allSatisfy { $0.totalSize == tree.totalSize })
}
