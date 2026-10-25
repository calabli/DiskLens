import Foundation
import Testing
@testable import DiskLensCore

@Test func largeFilesAreListedLargestFirstWithoutBundleInternals() throws {
    let root = NSTemporaryDirectory() + "disklens-large-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    func write(_ relative: String, bytes: Int) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: path))
    }
    try write("Movies/trip.mov", bytes: 900_000)
    try write("Downloads/setup.dmg", bytes: 600_000)
    try write("Downloads/notes.txt", bytes: 10_000)
    try write("Library/Caches/blob.bin", bytes: 300_000)
    try write("Applications/Big.app/Contents/Resources/assets.car", bytes: 800_000)

    let tree = try DiskScanner().scan(root)
    let files = LargeFileFinder.find(in: tree, minimumSize: 200_000, homePath: root)

    #expect(files.map(\.name) == ["trip.mov", "Big.app", "setup.dmg", "blob.bin"])
    #expect(files[0].category == .video)
    #expect(files[0].location == "~/Movies")
    #expect(files[1].category == .application)
    #expect(files.first { $0.name == "blob.bin" }?.isAppData == true)
    #expect(files.first { $0.name == "setup.dmg" }?.isAppData == false)

    let capped = LargeFileFinder.find(in: tree, minimumSize: 200_000, limit: 2, homePath: root)
    #expect(capped.count == 2)
}
