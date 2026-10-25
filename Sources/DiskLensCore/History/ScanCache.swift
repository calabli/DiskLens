import CoreServices
import Foundation

/// A finished scan saved to disk, with what is needed to bring it up to date
/// later from the file system's change journal.
public struct CachedScan: Sendable {
    public let tree: FileTree
    public let scannedAt: Date
    /// FSEvents event id taken just before the scan started; changes after it
    /// are not in `tree`.
    public let eventID: UInt64
    /// The FSEvents database the event id belongs to; ids from another one mean nothing.
    public let journalID: String?

    public init(tree: FileTree, scannedAt: Date, eventID: UInt64, journalID: String?) {
        self.tree = tree
        self.scannedAt = scannedAt
        self.eventID = eventID
        self.journalID = journalID
    }
}

/// Saves scans as one LZ4-compressed binary file per scanned folder. The
/// format stores the per-entry arrays back to back; totals and child order
/// are rebuilt on load.
public struct ScanCache: Sendable {
    public let directory: URL

    private static let magic: UInt32 = 0x4443_4C44  // "DLCD"
    private static let version: UInt32 = 1

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Caches/<bundle id>/Scans, or a DiskLens folder outside an app bundle.
    public static var standard: ScanCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "app.disklens.DiskLens"
        return ScanCache(directory: caches.appendingPathComponent(id).appendingPathComponent("Scans"))
    }

    public func url(forRoot rootPath: String) -> URL {
        // A readable file name, plus a hash so different paths never collide.
        let readable = rootPath.split(separator: "/").suffix(2).joined(separator: "-")
            .replacingOccurrences(of: " ", with: "_")
        let hash = rootPath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent("\(readable)-\(String(hash, radix: 16)).dlscan")
    }

    public func save(_ scan: CachedScan) throws {
        let tree = scan.tree
        var writer = Writer()
        writer.put(Self.magic)
        writer.put(Self.version)
        writer.put(scan.scannedAt.timeIntervalSince1970)
        writer.put(scan.eventID)
        writer.put(string: scan.journalID ?? "")
        writer.put(string: tree.rootPath)
        let s = tree.stats
        for value in [s.files, s.directories, s.unreadableDirectories, s.skippedMounts, s.duplicateHardLinks] {
            writer.put(Int64(value))
        }
        writer.put(s.duration)

        // Removed nodes (trashed since the scan) are left out; ids are renumbered.
        var newID = [Int32](repeating: -1, count: tree.count)
        var order: [Int] = []
        order.reserveCapacity(tree.count)
        for node in 0..<tree.count where node == 0 || newID[Int(tree.parents[node])] >= 0 {
            if node > 0 && tree.isRemovedItself(node) { continue }
            newID[node] = Int32(order.count)
            order.append(node)
        }
        writer.put(UInt64(order.count))
        for node in order { writer.put(node == 0 ? Int32(-1) : newID[Int(tree.parents[node])]) }
        for node in order { writer.put(tree.kinds[node].rawValue) }
        for node in order { writer.put(tree.ownSizes[node]) }
        for node in order { writer.put(tree.modTimes[node]) }
        for node in order {
            tree.names.withUTF8(node) { bytes in
                writer.put(UInt16(bytes.count))
                writer.data.append(contentsOf: bytes)
            }
        }

        let compressed = try (writer.data as NSData).compressed(using: .lz4) as Data
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try compressed.write(to: url(forRoot: tree.rootPath), options: .atomic)
    }

    public func load(rootPath: String) -> CachedScan? {
        guard let compressed = try? Data(contentsOf: url(forRoot: rootPath)),
              let data = try? (compressed as NSData).decompressed(using: .lz4) as Data
        else { return nil }
        var reader = Reader(data: data)
        guard reader.get(UInt32.self) == Self.magic, reader.get(UInt32.self) == Self.version,
              let scannedAt = reader.get(Double.self), let eventID = reader.get(UInt64.self),
              let journalID = reader.getString(), let storedRoot = reader.getString(), storedRoot == rootPath
        else { return nil }
        var stats = ScanStats()
        guard let files = reader.get(Int64.self), let dirs = reader.get(Int64.self),
              let unreadable = reader.get(Int64.self), let mounts = reader.get(Int64.self),
              let links = reader.get(Int64.self), let duration = reader.get(Double.self),
              let count64 = reader.get(UInt64.self)
        else { return nil }
        (stats.files, stats.directories, stats.unreadableDirectories) = (Int(files), Int(dirs), Int(unreadable))
        (stats.skippedMounts, stats.duplicateHardLinks, stats.duration) = (Int(mounts), Int(links), duration)

        let count = Int(count64)
        var parents = ChunkedArray<Int32>()
        var kinds = ChunkedArray<EntryKind>()
        var ownSizes = ChunkedArray<Int64>()
        var modTimes = ChunkedArray<Int64>()
        var names = NamePool()
        for _ in 0..<count {
            guard let parent = reader.get(Int32.self) else { return nil }
            parents.append(parent)
        }
        for _ in 0..<count {
            guard let raw = reader.get(UInt8.self), let kind = EntryKind(rawValue: raw) else { return nil }
            kinds.append(kind)
        }
        for _ in 0..<count {
            guard let size = reader.get(Int64.self) else { return nil }
            ownSizes.append(size)
        }
        for _ in 0..<count {
            guard let time = reader.get(Int64.self) else { return nil }
            modTimes.append(time)
        }
        for _ in 0..<count {
            guard let length = reader.get(UInt16.self), reader.withBytes(Int(length), { names.append(bytes: $0) })
            else { return nil }
        }
        let tree = FileTree(rootPath: rootPath, names: names, parents: parents, kinds: kinds,
                            ownSizes: ownSizes, modTimes: modTimes, stats: stats)
        return CachedScan(tree: tree, scannedAt: Date(timeIntervalSince1970: scannedAt), eventID: eventID,
                          journalID: journalID.isEmpty ? nil : journalID)
    }

    public func remove(rootPath: String) {
        try? FileManager.default.removeItem(at: url(forRoot: rootPath))
    }
}

private struct Writer {
    var data = Data()

    mutating func put<T: BitwiseCopyable>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    mutating func put(string: String) {
        let bytes = Array(string.utf8)
        put(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    mutating func get<T: BitwiseCopyable>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return value
    }

    mutating func getString() -> String? {
        guard let length = get(UInt32.self), offset + Int(length) <= data.count else { return nil }
        let string = String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + Int(length))],
                            as: UTF8.self)
        offset += Int(length)
        return string
    }

    mutating func withBytes(_ count: Int, _ body: (UnsafeBufferPointer<UInt8>) -> Void) -> Bool {
        guard offset + count <= data.count else { return false }
        data.withUnsafeBytes { raw in
            body(UnsafeBufferPointer(rebasing: raw.bindMemory(to: UInt8.self)[offset..<(offset + count)]))
        }
        offset += count
        return true
    }
}
