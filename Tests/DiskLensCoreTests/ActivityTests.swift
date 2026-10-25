import Foundation
import Testing
@testable import DiskLensCore

private func temporaryStore() throws -> (ActivityStore, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-activity-" + UUID().uuidString + "/a.sqlite")
    return (try ActivityStore(url: url), url.deletingLastPathComponent())
}

@Test func storeAddsUpWritesAndGrowthPerMinute() throws {
    let (store, folder) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }

    try store.addWrites(["Xcode": 100, "Chrome": 50], minute: 60)
    try store.addWrites(["Xcode": 300, "Idle": 0], minute: 60)
    try store.addWrites(["Chrome": 500], minute: 120)
    try store.addGrowth([("/h/Library/Caches/x", "x", 1_000), ("/h/Downloads", "下载", 4_000)], minute: 60)
    try store.addGrowth([("/h/Library/Caches/x", "x", -300)], minute: 120)

    #expect(store.topWriters(from: 0, to: 180) == [.init(app: "Chrome", bytes: 550), .init(app: "Xcode", bytes: 400)])
    #expect(store.topWriters(from: 60, to: 120).first == .init(app: "Xcode", bytes: 400))
    #expect(store.growthByOwner(from: 0, to: 180) == [.init(app: "下载", bytes: 4_000), .init(app: "x", bytes: 700)])
    #expect(store.growthFolders(owner: "x", from: 0, to: 180).map(\.bytes) == [700])
}

@Test func volumeSeriesReportsFirstAndLastUsedPerBucket() throws {
    let (store, folder) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Two hours of samples, used space growing 1,000 a minute.
    for minute in stride(from: Int64(0), to: 7_200, by: 60) {
        try store.recordVolume(used: 1_000_000 + minute / 60 * 1_000, available: 0, minute: minute)
    }

    let hours = store.volumeSeries(from: 0, to: 7_200, bucket: 3_600)

    #expect(hours.map(\.time) == [0, 3_600])
    #expect(hours[0].firstUsed == 1_000_000 && hours[0].lastUsed == 1_059_000)
    #expect(hours[1].change == 59_000)
    // Shifted buckets, as for local midnight in a zone 30 minutes ahead of GMT.
    let shifted = store.volumeSeries(from: 0, to: 7_200, bucket: 3_600, offset: 1_800)
    #expect(shifted.map(\.time) == [-1_800, 1_800, 5_400])
    #expect(shifted[0].change == 29_000)
    #expect(store.firstRecord() == 0)
    try store.prune(before: 3_600)
    #expect(store.firstRecord() == 3_600)
}

@Test func foldersAreAttributedToTheirOwners() {
    let home = "/Users/me"
    func owner(_ relative: String) -> String { FolderOwner.owner(of: home + "/" + relative, home: home) }
    #expect(owner("Library/Containers/com.tencent.xinWeChat/Data/Library/Caches") == "com.tencent.xinWeChat")
    #expect(owner("Library/Group Containers/group.com.example.App/x") == "com.example.App")
    #expect(owner("Library/Application Support/Google/Chrome/Default") == "Google")
    #expect(owner("Library/Developer/Xcode/DerivedData/App-abc") == "Xcode")
    #expect(owner("Downloads") == "下载")
    #expect(owner("code/app/node_modules/react") == "开发项目依赖")
    #expect(owner("Movies/clips") == "影片")
    #expect(owner("go/pkg") == "~/go")
    #expect(owner("Desktop/app/build") == "桌面")  // "build" alone is not a dependency folder
}

@Test func helperProcessesCountTowardTheirApp() {
    #expect(WriteSampler.owner(ofExecutable: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper") == "Google Chrome")
    #expect(WriteSampler.owner(ofExecutable: "/opt/homebrew/bin/node") == "node")
}

@Test func samplerSeesThisProcessWriting() throws {
    let sampler = WriteSampler()
    _ = sampler.sample()
    let path = NSTemporaryDirectory() + "disklens-write-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    var data = Data(count: 8_000_000)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 8_000_000) }
    try data.write(to: URL(fileURLWithPath: path))
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.synchronize()  // make the kernel count it as written to disk
    try handle.close()

    let totals = sampler.sample()

    #expect(totals.values.reduce(0, +) >= 8_000_000)
}

@Test func trackerMeasuresGrowthOfChangedFolders() throws {
    let base = NSTemporaryDirectory() + "disklens-growth-" + UUID().uuidString
    let root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(atPath: root + "/Downloads", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    func write(_ relative: String, bytes: Int) throws {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: root + "/" + relative))
    }
    try write("Downloads/old.bin", bytes: 100_000)
    Thread.sleep(forTimeInterval: 1.1)  // file times have one-second resolution; old.bin must predate the tracker
    let tracker = FolderGrowthTracker(root: root, queue: DispatchQueue(label: "test"))

    // First sight of the folder: only the file written since counts.
    try write("Downloads/new.bin", bytes: 300_000)
    tracker.folderChanged([root + "/Downloads/"])
    let first = tracker.takeChanges()
    #expect(first.count == 1)
    #expect(first[0].owner == "下载")
    #expect(first[0].bytes >= 300_000 && first[0].bytes < 400_000)

    // Known folder: exact difference, including shrinking.
    try FileManager.default.removeItem(atPath: root + "/Downloads/old.bin")
    tracker.folderChanged([root + "/Downloads"])
    let second = tracker.takeChanges()
    #expect(second.count == 1 && second[0].bytes <= -100_000)

    tracker.folderChanged([root + "/Downloads"])
    #expect(tracker.takeChanges().isEmpty)
}

@Test func storeKeepsTheLatestMetaValue() throws {
    let (store, folder) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(store.meta("x") == nil)
    try store.setMeta("x", "denied")
    try store.setMeta("x", "granted")
    #expect(store.meta("x")?.value == "granted")
}

@Test func fullDiskAccessProbeGivesAnAnswerHere() {
    // Test runners usually lack Full Disk Access; either way the probe must decide.
    #expect(FullDiskAccess.status() != .unknown)
}
