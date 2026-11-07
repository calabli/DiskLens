import CryptoKit
import Darwin
import Foundation

public struct DuplicateFile: Sendable, Hashable, Identifiable {
    public let node: Int
    public let path: String
    public let modified: Date
    /// Bytes only this file uses. A copy made by APFS cloning shares its blocks
    /// with the original, so deleting it frees next to nothing.
    public let privateSize: Int64
    /// Bytes the file takes on disk, less than its length when APFS compressed it.
    public let allocatedSize: Int64

    public var id: Int { node }
}

public struct DuplicateGroup: Sendable, Identifiable {
    /// The content hash, unique per group.
    public let id: String
    /// Length of each copy.
    public let size: Int64
    /// The copy suggested to keep comes first; the rest are the extras.
    public let files: [DuplicateFile]

    public init(id: String, size: Int64, files: [DuplicateFile]) {
        self.id = id
        self.size = size
        self.files = files
    }

    /// Space freed by deleting every copy but the first.
    public var reclaimable: Int64 { files.dropFirst().reduce(0) { $0 + $1.privateSize } }
    /// The copies already share their blocks (APFS clones), so deleting them frees little.
    public var isMostlyClones: Bool { reclaimable < files.dropFirst().reduce(0) { $0 + $1.allocatedSize } / 4 }
}

public struct DuplicateProgress: Sendable {
    public let bytesHashed: Int64
    public let bytesToHash: Int64
}

/// Finds files with identical contents among the files of a scan. Only files
/// of equal size can match, so most files are ruled out by the scan alone; the
/// rest are compared by length, then by a hash of their first and last 16 KB,
/// then by a full SHA-256. A file APFS compressed takes less space than its
/// length, so compressed files skip the first step and are matched by length.
public final class DuplicateFinder: @unchecked Sendable {
    public var minimumSize: Int64 = 1_000_000
    /// Leave out ~/Library, where copies usually belong to apps and are not the user's to remove.
    public var includeLibrary = false
    public let homePath: String
    private let lock = NSLock()
    private var cancelled = false

    public init(homePath: String = UserHome.path) {
        self.homePath = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Duplicate groups, those freeing the most space first.
    public func find(in tree: FileTree, progress: (@Sendable (DuplicateProgress) -> Void)? = nil) throws -> [DuplicateGroup] {
        // 1. Same allocated size in the scan.
        var bySize: [Int64: [Int]] = [:]
        var compressed: [Int] = []
        for node in 1..<max(tree.count, 1) where tree.kinds[node] == .file {
            if tree.flags(of: node).contains(.compressed) {
                compressed.append(node)
            } else if tree.ownSizes[node] >= minimumSize {
                bySize[tree.ownSizes[node], default: []].append(node)
            }
        }
        compressed = compressed.filter { !tree.isRemoved($0) && isEligible($0, in: tree) }
        let compressedFiles = stat(compressed, in: tree).filter { $0.length >= minimumSize }
        // An uncompressed copy of a compressed file takes its length rounded up to whole blocks.
        let compressedSizes = Set(compressedFiles.map { ($0.length + 4095) / 4096 * 4096 })
        let candidates = bySize.values.filter { $0.count > 1 || compressedSizes.contains(tree.ownSizes[$0[0]]) }
            .flatMap { $0 }
            .filter { !tree.isRemoved($0) && isEligible($0, in: tree) }

        // 2. Same exact length, and not another name for the same file.
        var byLength: [Int64: [Candidate]] = [:]
        var seenFiles = Set<FileID>()
        for file in stat(candidates, in: tree) + compressedFiles where seenFiles.insert(file.id).inserted {
            byLength[file.length, default: []].append(file)
        }
        let sameLength = byLength.values.filter { $0.count > 1 }
        if isCancelled { throw ScanError.cancelled }

        // 3. Same first and last 16 KB.
        let partial = try regroup(sameLength) { try Self.edgeHash(of: $0.path, length: $0.length) }

        // 4. Same full contents.
        let bytesToHash = partial.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.length }
        let hashed = Counter()
        let full = try regroup(partial) { file -> String in
            let hash = try Self.fullHash(of: file.path, length: file.length) { self.isCancelled }
            progress?(DuplicateProgress(bytesHashed: hashed.add(file.length), bytesToHash: bytesToHash))
            return hash
        }

        return full.map { group in
            let ordered = Self.orderedForKeeping(group, home: homePath, sizes: tree.ownSizes)
            let files = ordered.map {
                DuplicateFile(node: $0.node, path: $0.path, modified: $0.modified,
                              privateSize: Self.privateSize(of: $0.path) ?? tree.ownSizes[$0.node],
                              allocatedSize: tree.ownSizes[$0.node])
            }
            return DuplicateGroup(id: group[0].hash ?? UUID().uuidString, size: group[0].length, files: files)
        }
        .sorted { $0.reclaimable > $1.reclaimable }
    }

    private struct Candidate: Sendable {
        let node: Int
        let path: String
        let length: Int64
        let id: FileID
        let modified: Date
        var hash: String?
    }

    /// A file's volume and inode: hard links to one file share it.
    private struct FileID: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// The regular files among `nodes`, with their exact length.
    private func stat(_ nodes: [Int], in tree: FileTree) -> [Candidate] {
        concurrentMap(nodes) { node -> Candidate? in
            let path = tree.path(of: node)
            var st = Darwin.stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
            return Candidate(node: node, path: path, length: Int64(st.st_size),
                             id: FileID(device: st.st_dev, inode: st.st_ino),
                             modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
        }
        .compactMap { $0 ?? nil }
    }

    /// A file the user manages. Files inside app bundles, dependency folders
    /// (node_modules, .venv…) and hidden folders (.git, .npm…) belong to tools:
    /// identical copies there are expected, and deleting one breaks its owner.
    private func isEligible(_ node: Int, in tree: FileTree) -> Bool {
        Self.isEligible(node, in: tree, homePath: homePath, includeLibrary: includeLibrary)
    }

    static func isEligible(_ node: Int, in tree: FileTree, homePath: String, includeLibrary: Bool) -> Bool {
        var i = Int(tree.parents[node])
        while i > 0 {
            let name = tree.names[i]
            if FileCategory.of(name: name, kind: tree.kinds[i]).isOpaqueBundle { return false }
            if CleanupAdvisor.dependencyFolders[name] != nil && name != "build" && name != "target" { return false }
            if name.hasPrefix(".") && name != ".Trash" { return false }
            i = Int(tree.parents[i])
        }
        if !includeLibrary {
            let path = tree.path(of: node)
            if path.hasPrefix(homePath + "/Library/") { return false }
        }
        return true
    }

    /// Splits each group by `key`, keeping the parts with more than one file.
    private func regroup(_ groups: [[Candidate]], key: @escaping @Sendable (Candidate) throws -> String) throws -> [[Candidate]] {
        let keyed = concurrentMap(groups.flatMap { $0 }) { file -> Candidate? in
            guard !self.isCancelled, let hash = try? key(file) else { return nil }
            var keyed = file
            keyed.hash = hash
            return keyed
        }
        if isCancelled { throw ScanError.cancelled }
        var buckets: [String: [Candidate]] = [:]
        for file in keyed.compactMap({ $0 ?? nil }) {
            buckets["\(file.length)-\(file.hash!)", default: []].append(file)
        }
        return buckets.values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
    }

    private func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], _ transform: @escaping @Sendable (T) -> R) -> [R?] {
        let results = ResultBox<R>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            results.set(index, transform(items[index]))
        }
        return results.values
    }

    /// The copy to keep first: not in Downloads or the Trash if possible, then the one taking
    /// the least space (a compressed copy), then the oldest.
    private static func orderedForKeeping(_ files: [Candidate], home: String,
                                          sizes: ChunkedArray<Int64>) -> [Candidate] {
        func penalty(_ path: String) -> Int {
            if path.hasPrefix(home + "/.Trash/") { return 2 }
            if path.hasPrefix(home + "/Downloads/") { return 1 }
            return 0
        }
        return files.sorted {
            (penalty($0.path), sizes[$0.node], $0.modified, $0.path) < (penalty($1.path), sizes[$1.node], $1.modified, $1.path)
        }
    }

    // MARK: Reading files

    private static let edgeLength = 16 * 1024

    static func edgeHash(of path: String, length: Int64) throws -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.cannotRead(path: path, errno: errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: edgeLength)
        for offset in Set([0, max(length - Int64(edgeLength), 0)]).sorted() {
            let read = pread(fd, &buffer, edgeLength, off_t(offset))
            guard read >= 0 else { throw ScanError.cannotRead(path: path, errno: errno) }
            hasher.update(data: buffer.prefix(read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(of path: String, length: Int64, cancelled: () -> Bool) throws -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.cannotRead(path: path, errno: errno) }
        defer { close(fd) }
        // Don't push the user's working set out of the file cache.
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        // A small file needs no 1 MB buffer.
        var buffer = [UInt8](repeating: 0, count: Int(min(max(length, 4096), 1 << 20)))
        while true {
            if cancelled() { throw ScanError.cancelled }
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw ScanError.cannotRead(path: path, errno: errno) }
            if count == 0 { break }
            hasher.update(data: buffer.prefix(count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes of the file not shared with any clone.
    static func privateSize(of path: String) -> Int64? {
        CloneInfo.of(path)?.privateSize
    }
}

private final class ResultBox<R>: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [R?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: R) {
        lock.withLock { values[index] = value }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ value: Int64) -> Int64 {
        lock.withLock {
            total += value
            return total
        }
    }
}
