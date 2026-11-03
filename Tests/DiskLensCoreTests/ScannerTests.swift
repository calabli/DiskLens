import Darwin
import Foundation
import Testing
@testable import DiskLensCore

/// A throwaway directory tree, removed when the test ends.
private final class Sandbox {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "disklens-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ relative: String, bytes: Int) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        // Random bytes so APFS compression cannot shrink the file.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Allocated bytes as `stat` reports them, the same measure `du` uses.
    func allocated(_ relative: String) -> Int64 {
        var st = stat()
        lstat(root + "/" + relative, &st)
        return Int64(st.st_blocks) * 512
    }
}

private func node(_ tree: FileTree, _ relative: String) -> Int? {
    var current = 0
    for part in relative.split(separator: "/") {
        guard let next = tree.children(of: current).first(where: { tree.names[Int($0)] == part }) else { return nil }
        current = Int(next)
    }
    return current
}

@Test func filesAndFoldersAreCountedWithAllocatedSizes() throws {
    let box = try Sandbox()
    try box.write("a/one.bin", bytes: 10_000)
    try box.write("a/b/two.bin", bytes: 300_000)
    try box.write("c/three.bin", bytes: 1)

    let tree = try DiskScanner().scan(box.root)

    #expect(tree.stats.files == 3)
    #expect(tree.stats.unreadableDirectories == 0)
    let a = try #require(node(tree, "a"))
    let ab = try #require(node(tree, "a/b"))
    #expect(tree.totalSizes[ab] == box.allocated("a/b") + box.allocated("a/b/two.bin"))
    #expect(tree.totalSizes[a] == box.allocated("a") + box.allocated("a/one.bin") + tree.totalSizes[ab])
    #expect(tree.fileCounts[a] == 2)
    #expect(tree.fileCounts[0] == 3)
}

@Test func childrenAreSortedLargestFirstAndPathsResolve() throws {
    let box = try Sandbox()
    try box.write("small/x.bin", bytes: 4_000)
    try box.write("big/y.bin", bytes: 2_000_000)
    try box.write("medium/z.bin", bytes: 200_000)

    let tree = try DiskScanner().scan(box.root)

    let names = tree.children(of: 0).map { tree.names[Int($0)] }
    #expect(names == ["big", "medium", "small"])
    let y = try #require(node(tree, "big/y.bin"))
    #expect(tree.path(of: y) == box.root + "/big/y.bin")
}

@Test func hardLinksAreCountedOnce() throws {
    let box = try Sandbox()
    try box.write("original.bin", bytes: 500_000)
    try FileManager.default.createDirectory(atPath: box.root + "/links", withIntermediateDirectories: true)
    #expect(link(box.root + "/original.bin", box.root + "/links/copy.bin") == 0)

    let tree = try DiskScanner().scan(box.root)

    #expect(tree.stats.files == 2)
    #expect(tree.stats.duplicateHardLinks == 1)
    let fileBytes = box.allocated("original.bin")
    let total = tree.totalSizes[0] - box.allocated("") - box.allocated("links")
    #expect(total == fileBytes)
}

@Test func symlinksAreNotFollowed() throws {
    let box = try Sandbox()
    try box.write("data/big.bin", bytes: 1_000_000)
    try FileManager.default.createSymbolicLink(atPath: box.root + "/alias", withDestinationPath: box.root + "/data")

    let tree = try DiskScanner().scan(box.root)

    let alias = try #require(node(tree, "alias"))
    #expect(tree.kinds[alias] == .symlink)
    #expect(tree.children(of: alias).isEmpty)
    #expect(tree.stats.files == 2)
}

@Test func manyThreadsAndOneThreadAgree() throws {
    let box = try Sandbox()
    for i in 0..<40 {
        try box.write("d\(i % 7)/e\(i % 3)/f\(i).bin", bytes: 1_000 * (i + 1))
    }
    var single = ScanOptions()
    single.threadCount = 1
    var many = ScanOptions()
    many.threadCount = 8

    let a = try DiskScanner(options: single).scan(box.root)
    let b = try DiskScanner(options: many).scan(box.root)

    #expect(a.totalSize == b.totalSize)
    #expect(a.count == b.count)
}

@Test func missingRootThrows() {
    #expect(throws: ScanError.self) {
        try DiskScanner().scan("/definitely/not/here/\(UUID().uuidString)")
    }
}

@Test func byteFormatUsesDecimalUnits() {
    #expect(ByteFormat.string(999) == "999 B")
    #expect(ByteFormat.string(1_500_000) == "1.5 MB")
    #expect(ByteFormat.string(123_000_000_000) == "123 GB")
}

@Test func cancelledScanThrows() throws {
    let box = try Sandbox()
    try box.write("a/b.bin", bytes: 1_000)
    let scanner = DiskScanner()
    scanner.cancel()
    #expect(throws: ScanError.self) {
        try scanner.scan(box.root)
    }
}

@Test func snapshotIsNilWhenIdleAndFinalTreeKeepsNodeIds() throws {
    let box = try Sandbox()
    for i in 0..<200 {
        try box.write("d\(i % 10)/f\(i).bin", bytes: 100)
    }
    let scanner = DiskScanner()
    #expect(scanner.snapshot() == nil)

    let tree = try scanner.scan(box.root)

    #expect(scanner.snapshot() == nil)
    // Snapshots are prefixes of the final arrays, so ids taken from one stay valid.
    for node in 1..<tree.count {
        #expect(Int(tree.parents[node]) < node)
    }
}

@Test func openingByPathAndByParentGiveTheSameTree() throws {
    let box = try Sandbox()
    for i in 0..<60 {
        try box.write("a\(i % 5)/b\(i % 4)/c\(i % 3)/d/f\(i).bin", bytes: 500 * (i + 1))
    }
    var byPath = ScanOptions()
    byPath.openFolderLimit = 0
    var byParent = ScanOptions()
    byParent.openFolderLimit = 10_000

    let a = try DiskScanner(options: byPath).scan(box.root)
    let b = try DiskScanner(options: byParent).scan(box.root)

    #expect(a.totalSize == b.totalSize)
    #expect(a.count == b.count)
    #expect(a.stats.files == 60 && b.stats.files == 60)
    #expect(a.stats.unreadableDirectories == 0 && b.stats.unreadableDirectories == 0)
}

@Test func clonesAreFlaggedAndCountedOnceWhenFreeing() throws {
    let box = try Sandbox()
    try box.write("a/original.bin", bytes: 1_000_000)
    try box.write("c/other.bin", bytes: 1_000_000)
    try FileManager.default.createDirectory(atPath: box.root + "/b", withIntermediateDirectories: true)
    guard clonefile(box.root + "/a/original.bin", box.root + "/b/copy.bin", 0) == 0 else {
        return  // Not on APFS.
    }

    let tree = try DiskScanner().scan(box.root)
    let (a, b, c) = (try #require(node(tree, "a")), try #require(node(tree, "b")), try #require(node(tree, "c")))
    #expect(tree.flags(of: try #require(node(tree, "b/copy.bin"))).contains(.mayShareBlocks))
    #expect(!tree.flags(of: try #require(node(tree, "c/other.bin"))).contains(.mayShareBlocks))

    // The copy alone frees almost nothing: the original still uses its blocks.
    #expect(FreeableSpace.estimate([b], in: tree) < 100_000)
    // Both copies together free the shared blocks once.
    let both = FreeableSpace.estimate([a, b], in: tree)
    #expect(abs(both - (tree.totalSizes[a] + tree.totalSizes[b] - box.allocated("b/copy.bin"))) < 100_000)
    #expect(FreeableSpace.estimate([c], in: tree) == tree.totalSizes[c])
}

@Test func compressedFilesAreFlaggedAndFlagsSurviveTheCache() throws {
    let box = try Sandbox()
    let text = String(repeating: "DiskLens compresses well. ", count: 20_000)
    try text.write(toFile: box.root + "/plain.txt", atomically: true, encoding: .utf8)
    // Copying on the same volume makes a clone, so pack it and unpack it compressed.
    for arguments in [["-c", box.root + "/plain.txt", box.root + "/plain.cpio"],
                      ["-x", "--hfsCompression", box.root + "/plain.cpio", box.root + "/packed"]] {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = arguments
        try ditto.run()
        ditto.waitUntilExit()
    }

    let tree = try DiskScanner().scan(box.root)
    let packed = try #require(node(tree, "packed/plain.txt"))
    #expect(tree.flags(of: packed).contains(.compressed))
    #expect(!tree.flags(of: try #require(node(tree, "plain.txt"))).contains(.compressed))

    let cache = ScanCache(directory: URL(fileURLWithPath: box.root + "/cache"))
    try cache.save(CachedScan(tree: tree, scannedAt: Date(), eventID: 0, journalID: nil))
    let loaded = try #require(cache.load(rootPath: box.root)).tree
    #expect(loaded.flags(of: try #require(node(loaded, "packed/plain.txt"))).contains(.compressed))
    #expect(loaded.hasFileFlags)
    #expect(try TreeUpdater.update(loaded, applying: ChangeSet(folders: [], subtrees: [])).hasFileFlags)
}
