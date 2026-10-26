import Foundation
import Testing
@testable import DiskLensCore

@Test func cleanupsAreLoggedAndCanBePutBack() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-log-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let original = root.appendingPathComponent("project/build/cache.bin").path
    let trash = root.appendingPathComponent("Trash/cache.bin").path
    try fm.createDirectory(atPath: (trash as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    // As if moved to the Trash, with its folder gone since.
    try Data(count: 4096).write(to: URL(fileURLWithPath: trash))

    let log = CleanupLog(file: root.appendingPathComponent("log.json"))
    let item = CleanupRecord.Item(originalPath: original, trashPath: trash, size: 4096, isDirectory: false)
    let record = CleanupRecord(items: [item])
    try log.add(record)
    try log.add(CleanupRecord(items: []))  // empty cleanups are not logged
    #expect(log.records().count == 1 && log.records()[0].totalSize == 4096)
    #expect(log.records()[0].items[0].state == .inTrash)

    try log.putBack(item, of: record.id)
    #expect(fm.fileExists(atPath: original) && !fm.fileExists(atPath: trash))
    #expect(log.records()[0].items[0].state == .restored)
    #expect(throws: CleanupLog.PutBackError.notInTrash) { try log.putBack(item, of: record.id) }

    // Something new in the original place is never overwritten.
    try Data(count: 1).write(to: URL(fileURLWithPath: trash))
    #expect(throws: CleanupLog.PutBackError.occupied) { try log.putBack(item, of: record.id) }
}

@Test func emptiedTrashShowsAsGone() {
    let item = CleanupRecord.Item(originalPath: "/nowhere/a", trashPath: "/nowhere/.Trash/a", size: 1, isDirectory: false)
    #expect(item.state == .gone)
}
