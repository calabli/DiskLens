import Darwin
import Foundation
import Testing
@testable import DiskLensCore

private final class Home {
    let root: String

    init() throws {
        let base = NSTemporaryDirectory() + "disklens-dupes-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func finder() -> DuplicateFinder {
        let finder = DuplicateFinder(homePath: root)
        finder.minimumSize = 100_000
        return finder
    }
}

private func random(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
    return data
}

@Test func identicalFilesAreGroupedAndTheDownloadCopyIsTheExtra() throws {
    let home = try Home()
    let photo = random(400_000)
    try home.write("Pictures/trip.jpg", photo)
    let copy = try home.write("Downloads/trip (1).jpg", photo)
    try home.write("Pictures/other.jpg", random(400_000))  // same size, different bytes

    let groups = try home.finder().find(in: try DiskScanner().scan(home.root))

    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.size == 400_000)
    #expect(group.files.map(\.path).last == copy)  // keep the one outside Downloads
    #expect(group.reclaimable >= 400_000)
    #expect(!group.isMostlyClones)
}

@Test func onlyTheFullHashSeparatesFilesThatDifferInTheMiddle() throws {
    let home = try Home()
    var a = random(300_000)
    var b = a
    b[150_000] ^= 0xFF  // same first and last 16 KB
    try home.write("a.bin", a)
    try home.write("b.bin", b)
    a.append(0)
    try home.write("c.bin", a)  // one byte longer

    #expect(try home.finder().find(in: try DiskScanner().scan(home.root)).isEmpty)
}

@Test func hardLinksAreNotDuplicates() throws {
    let home = try Home()
    let original = try home.write("one.bin", random(200_000))
    #expect(link(original, home.root + "/two.bin") == 0)

    #expect(try home.finder().find(in: try DiskScanner().scan(home.root)).isEmpty)
}

@Test func apfsClonesFreeAlmostNothing() throws {
    let home = try Home()
    let original = try home.write("big.bin", random(2_000_000))
    guard clonefile(original, home.root + "/big-clone.bin", 0) == 0 else {
        return  // not on APFS; nothing to test
    }

    let groups = try home.finder().find(in: try DiskScanner().scan(home.root))

    let group = try #require(groups.first)
    #expect(group.files.count == 2)
    #expect(group.isMostlyClones)
    #expect(group.reclaimable < 100_000)
}

@Test func libraryCopiesAreLeftOutUnlessAskedFor() throws {
    let home = try Home()
    let data = random(200_000)
    try home.write("Library/Application Support/App/a.dat", data)
    try home.write("Library/Caches/App/a.dat", data)
    let tree = try DiskScanner().scan(home.root)

    let finder = home.finder()
    #expect(try finder.find(in: tree).isEmpty)
    finder.includeLibrary = true
    #expect(try finder.find(in: tree).count == 1)
}

@Test func copiesOwnedByToolsAreLeftOut() throws {
    let home = try Home()
    let data = random(200_000)
    try home.write("code/a/node_modules/pkg/lib.node", data)
    try home.write("code/b/node_modules/pkg/lib.node", data)
    try home.write(".npm-global/lib/pkg/lib.node", data)
    try home.write("code/a/.git/objects/ab/cdef", data)

    #expect(try home.finder().find(in: try DiskScanner().scan(home.root)).isEmpty)
}

@Test func storageBreakdownReadsThisMachinesContainer() throws {
    let breakdown = try StorageBreakdown.load()
    #expect(breakdown.containerSize > 0 && breakdown.containerFree > 0)
    #expect(breakdown.volumes.contains { $0.role == .data && $0.used > 0 })
    #expect(breakdown.volumes.contains { $0.role == .system })
    let used = breakdown.volumes.reduce(Int64(0)) { $0 + $1.used }
    // Volumes share the container; together they are close to what it reports as used.
    #expect(abs(Double(used - breakdown.containerUsed)) / Double(breakdown.containerUsed) < 0.05)
}

@Test func timeMachineSnapshotNamesCarryTheirDate() {
    let date = StorageBreakdown.snapshotDate("com.apple.TimeMachine.2026-10-24-101530.local")
    #expect(date != nil)
    #expect(StorageBreakdown.snapshotDate("com.apple.os.update-9A91EDBD") == nil)
}
