import Foundation
import Testing
@testable import DiskLensCore

@Test func chunkedArrayCrossesChunkBoundaries() {
    var array = ChunkedArray<Int32>()
    let n = ChunkedArray<Int32>.chunkSize * 2 + 5
    for i in 0..<n { array.append(Int32(i)) }
    #expect(array.count == n)
    #expect(array[0] == 0)
    #expect(array[ChunkedArray<Int32>.chunkSize - 1] == Int32(ChunkedArray<Int32>.chunkSize - 1))
    #expect(array[ChunkedArray<Int32>.chunkSize] == Int32(ChunkedArray<Int32>.chunkSize))
    #expect(array[n - 1] == Int32(n - 1))
}

@Test func copiesKeepTheirCountWhileTheOriginalGrows() {
    var array: ChunkedArray<Int64> = [1, 2, 3]
    let snapshot = array
    for i in 0..<ChunkedArray<Int64>.chunkSize { array.append(Int64(i)) }
    #expect(snapshot.count == 3)
    #expect(snapshot[2] == 3)
    #expect(array.count == 3 + ChunkedArray<Int64>.chunkSize)
}

@Test func namesNeverStraddleAChunk() {
    var pool = NamePool()
    let long = String(repeating: "é", count: 300)  // 600 UTF-8 bytes
    var expected: [String] = []
    // Enough names to cross several 64 KiB chunks at awkward offsets.
    for i in 0..<400 {
        let name = i % 3 == 0 ? long + "\(i)" : "name-\(i)"
        pool.append(name)
        expected.append(name)
    }
    pool.append("")
    expected.append("")
    #expect(pool.count == expected.count)
    for (i, name) in expected.enumerated() {
        #expect(pool[i] == name)
    }
}

@Test func aWholeDiskScanSortsIntoTheCategoriesOfSystemSettings() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-categories-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: url)
    }
    for file in ["Applications/App.app/binary", "Users/me/Library/Application Support/Some App/data",
                 "Users/me/Library/Application Support/com.apple.wallpaper/video", "Users/me/Library/Containers/x/data",
                 "Users/me/Library/Developer/Xcode/data", "Library/Developer/Tools/data",
                 "Users/me/Library/Caches/x/data", "Users/me/Library/Mail/inbox", "Users/me/Library/Mobile Documents/x",
                 "Users/me/Pictures/Photos Library.photoslibrary/photo", "Users/me/Desktop/note", "Users/me/.cache/x",
                 "Users/Shared/file", "private/var/vm/swapfile", "System/Library/AssetsV2/asset"] {
        try write(file)
    }
    let tree = try DiskScanner().scan(root.path)
    func size(_ path: String) -> Int64 { tree.totalSizes[tree.node(atPath: root.path + path)!] }
    let breakdown = StorageBreakdown(
        containerSize: 100_000_000_000, containerFree: 60_000_000_000,
        volumes: [.init(name: "Macintosh HD", role: .system, used: 12_000_000_000),
                  .init(name: "Preboot", role: .preboot, used: 5_000_000_000),
                  .init(name: "Data", role: .data, used: 23_000_000_000)],
        purgeable: 10_000_000_000, snapshots: [])

    let result = StorageCategories(tree: tree, breakdown: breakdown, homePath: "/Users/me")

    #expect(result.sizes[.macOS] == 17_000_000_000)
    #expect(result.sizes[.developer] == size("/Users/me/Library/Developer") + size("/Library/Developer"))
    #expect(result.sizes[.mail] == size("/Users/me/Library/Mail"))
    #expect(result.sizes[.otherUsers] == size("/Users/Shared"))
    // Apple's folders in Application Support are System Data; an app's are the app's.
    let appFolders = size("/Applications") + size("/Users/me/Library/Application Support/Some App")
        + size("/Users/me/Library/Containers")
    #expect(result.sizes[.applications] == appFolders)
    #expect(result.sizes[.photos] == size("/Users/me/Pictures/Photos Library.photoslibrary"))
    // Documents is the rest of home, hidden folders included, but not Library or the photo library.
    let documents = size("/Users/me") - size("/Users/me/Library") - result.sizes[.photos]!
    #expect(result.sizes[.documents] == documents)
    #expect(result.systemParts[.wallpapers] == size("/Users/me/Library/Application Support/com.apple.wallpaper"))
    #expect(result.systemParts[.systemAssets] == size("/System"))

    // The categories add up to what Settings shows: used space without the purgeable part.
    #expect(result.sizes.values.reduce(0, +) == 30_000_000_000)
    #expect(result.systemParts.values.reduce(0, +) == result.sizes[.systemData])
}
