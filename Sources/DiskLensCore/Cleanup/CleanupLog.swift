import Darwin
import Foundation

/// One time the basket was emptied into the Trash: what went where, so it can
/// be looked up later and put back.
public struct CleanupRecord: Codable, Sendable, Identifiable, Hashable {
    public struct Item: Codable, Sendable, Identifiable, Hashable {
        public let originalPath: String
        /// Where it is in the Trash (the Trash renames items whose name is taken).
        public let trashPath: String
        public let size: Int64
        public let isDirectory: Bool
        /// Set when DiskLens put it back.
        public var restoredAt: Date?

        public var id: String { trashPath }
        public var name: String { (originalPath as NSString).lastPathComponent }

        public init(originalPath: String, trashPath: String, size: Int64, isDirectory: Bool) {
            self.originalPath = originalPath
            self.trashPath = trashPath
            self.size = size
            self.isDirectory = isDirectory
        }

        public enum State: Sendable, Equatable {
            case inTrash
            case restored
            /// The Trash was emptied, or the item was moved out of it some other way.
            case gone
        }

        public var state: State {
            if restoredAt != nil { return .restored }
            var st = stat()
            return lstat(trashPath, &st) == 0 ? .inTrash : .gone
        }
    }

    public let id: UUID
    public let date: Date
    public var items: [Item]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    public init(date: Date = Date(), items: [Item]) {
        id = UUID()
        self.date = date
        self.items = items
    }
}

/// Every cleanup DiskLens has done, newest first, kept in a small JSON file.
public struct CleanupLog: Sendable {
    public let file: URL
    /// Older records beyond this are dropped.
    public static let limit = 500

    public init(file: URL) {
        self.file = file
    }

    /// ~/Library/Application Support/<bundle id>/cleanup-log.json.
    public static var standard: CleanupLog {
        let support = UserHome.directory(.applicationSupportDirectory)
        let id = Bundle.main.bundleIdentifier ?? "app.disklens.DiskLens"
        return CleanupLog(file: support.appendingPathComponent(id).appendingPathComponent("cleanup-log.json"))
    }

    public func records() -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CleanupRecord].self, from: data)) ?? []
    }

    public func add(_ record: CleanupRecord) throws {
        guard !record.items.isEmpty else { return }
        try save(Array(([record] + records()).prefix(Self.limit)))
    }

    public enum PutBackError: Error, CustomStringConvertible, Equatable {
        case notInTrash
        case occupied
        case failed(String)

        public var description: String {
            switch self {
            case .notInTrash: "已经不在废纸篓里了"
            case .occupied: "原来的位置已经有同名的项目"
            case let .failed(reason): reason
            }
        }
    }

    /// Moves an item from the Trash back where it was, recreating missing folders
    /// on the way, and notes that in the log.
    public func putBack(_ item: CleanupRecord.Item, of recordID: UUID) throws {
        let fm = FileManager.default
        var st = stat()
        guard lstat(item.trashPath, &st) == 0 else { throw PutBackError.notInTrash }
        guard lstat(item.originalPath, &st) != 0 else { throw PutBackError.occupied }
        do {
            let parent = (item.originalPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: item.trashPath, toPath: item.originalPath)
        } catch {
            throw PutBackError.failed((error as NSError).localizedDescription)
        }
        var all = records()
        if let r = all.firstIndex(where: { $0.id == recordID }),
           let i = all[r].items.firstIndex(where: { $0.trashPath == item.trashPath }) {
            all[r].items[i].restoredAt = Date()
            try? save(all)
        }
    }

    private func save(_ records: [CleanupRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: file, options: .atomic)
    }
}
