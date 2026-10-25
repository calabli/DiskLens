import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Do not descend into directories on another volume.
    public var stayOnVolume = true
    public var threadCount = max(ProcessInfo.processInfo.activeProcessorCount, 2)

    public init() {}
}

public enum ScanError: Error, CustomStringConvertible {
    case cannotRead(path: String, errno: Int32)
    case notADirectory(path: String)
    case cancelled

    public var description: String {
        switch self {
        case let .cannotRead(path, code): "cannot read \(path): \(String(cString: strerror(code)))"
        case let .notADirectory(path): "\(path) is not a directory"
        case .cancelled: "scan cancelled"
        }
    }
}

/// Walks a directory tree on several threads. Each thread reads whole directories
/// with `DirectoryReader` and hands the entries to a shared builder under a lock.
public final class DiskScanner: @unchecked Sendable {
    public let options: ScanOptions
    private let progress: (@Sendable (_ filesSoFar: Int) -> Void)?
    private let lock = NSLock()
    private var activeBuilder: TreeBuilder?
    private var activeStart = Date()
    private var cancelRequested = false

    public init(options: ScanOptions = ScanOptions(), progress: (@Sendable (Int) -> Void)? = nil) {
        self.options = options
        self.progress = progress
    }

    public func scan(_ rootPath: String) throws -> FileTree {
        let started = Date()
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw ScanError.cannotRead(path: rootPath, errno: errno) }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(path: rootPath) }

        let builder = TreeBuilder(rootPath: rootPath, rootDevice: st.st_dev, rootSize: Int64(st.st_blocks) * 512,
                                  stayOnVolume: options.stayOnVolume, progress: progress)
        let threads = (0..<options.threadCount).map { _ in
            Thread { builder.work() }
        }
        lock.withLock {
            activeBuilder = builder
            activeStart = started
            if cancelRequested { builder.cancel() }
        }
        defer { lock.withLock { activeBuilder = nil } }
        threads.forEach { $0.stackSize = 1 << 20; $0.start() }
        builder.waitUntilDone()

        if builder.isCancelled { throw ScanError.cancelled }

        if builder.stats.directories == 0, let code = builder.rootError {
            throw ScanError.cannotRead(path: rootPath, errno: code)
        }
        return builder.makeTree(duration: Date().timeIntervalSince(started))
    }

    /// The tree as scanned so far, or nil when no scan is running. Folders not
    /// read yet are empty, so sizes only grow. Node ids stay the same in later
    /// snapshots and in the final tree. Safe to call from any thread.
    public func snapshot() -> FileTree? {
        let (builder, started) = lock.withLock { (activeBuilder, activeStart) }
        return builder?.makeTree(duration: Date().timeIntervalSince(started))
    }

    /// Stops a running scan from any thread; `scan` then throws `ScanError.cancelled`.
    public func cancel() {
        lock.withLock {
            cancelRequested = true
            activeBuilder?.cancel()
        }
    }
}

private final class TreeBuilder: @unchecked Sendable {
    private let condition = NSCondition()
    private let rootPath: String
    private let rootDevice: Int32
    private let stayOnVolume: Bool
    private let progress: (@Sendable (Int) -> Void)?

    // Guarded by `condition`.
    private var names = NamePool()
    private var parents: ChunkedArray<Int32> = [-1]
    private var kinds: ChunkedArray<EntryKind> = [.directory]
    private var ownSizes = ChunkedArray<Int64>()
    private var modTimes: ChunkedArray<Int64> = [0]
    // Breadth-first: a live view sees every top-level folder early, then watches them grow.
    private var queue: [(node: Int32, path: String)]
    private var queueHead = 0
    private var pending = 1
    private var seenHardLinks = Set<UInt64>()
    private(set) var stats = ScanStats()
    private(set) var rootError: Int32?
    private(set) var isCancelled = false

    init(rootPath: String, rootDevice: Int32, rootSize: Int64, stayOnVolume: Bool,
         progress: (@Sendable (Int) -> Void)?) {
        self.rootPath = rootPath
        self.rootDevice = rootDevice
        self.stayOnVolume = stayOnVolume
        self.progress = progress
        names.append(rootPath)
        ownSizes.append(rootSize)
        queue = [(0, rootPath)]
    }

    func work() {
        let reader = DirectoryReader()
        var entries: [RawEntry] = []
        var nameBytes: [UInt8] = []
        while let job = nextJob() {
            entries.removeAll(keepingCapacity: true)
            nameBytes.removeAll(keepingCapacity: true)
            let code = reader.read(path: job.path, into: &entries, names: &nameBytes)
            finish(job, entries: entries, names: nameBytes, error: code)
        }
    }

    /// Returns once every queued directory has been read; idle workers exit on their own.
    func waitUntilDone() {
        condition.lock()
        while pending > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        pending -= queue.count - queueHead
        queue.removeAll()
        queueHead = 0
        condition.broadcast()
        condition.unlock()
    }

    private func nextJob() -> (node: Int32, path: String)? {
        condition.lock()
        defer { condition.unlock() }
        while queueHead == queue.count {
            if pending == 0 { return nil }
            condition.wait()
        }
        let job = queue[queueHead]
        queue[queueHead].path = ""
        queueHead += 1
        if queueHead >= 4096 && queueHead * 2 >= queue.count {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
        return job
    }

    private func finish(_ job: (node: Int32, path: String), entries: [RawEntry], names nameBytes: [UInt8],
                        error: Int32) {
        condition.lock()
        defer {
            pending -= 1
            condition.broadcast()
            condition.unlock()
        }

        if isCancelled { return }
        stats.directories += 1
        if error != 0 {
            if job.node == 0 { rootError = error }
            stats.unreadableDirectories += 1
            if stats.unreadableSamples.count < 20 { stats.unreadableSamples.append(job.path) }
        }

        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        for entry in entries {
            var size = entry.allocSize
            if entry.kind == .directory {
                if stayOnVolume && entry.device != rootDevice {
                    stats.skippedMounts += 1
                    continue
                }
            } else {
                stats.files += 1
                if entry.linkCount > 1 && !seenHardLinks.insert(entry.fileID).inserted {
                    stats.duplicateHardLinks += 1
                    size = 0
                }
            }

            let node = Int32(names.count)
            let name = nameBytes[entry.name]
            names.append(name)
            parents.append(job.node)
            kinds.append(entry.kind)
            ownSizes.append(size)
            modTimes.append(entry.modTime)

            if entry.kind == .directory {
                queue.append((node, prefix + String(decoding: name, as: UTF8.self)))
                pending += 1
            }
        }

        if let progress, stats.directories % 512 == 0 {
            progress(stats.files)
        }
    }

    /// Builds a tree from what has been read so far. Only copying references to
    /// the arrays happens under the lock; the roll-up and sorting run outside it.
    func makeTree(duration: Double) -> FileTree {
        condition.lock()
        let (names, parents, kinds, ownSizes, modTimes) = (names, parents, kinds, ownSizes, modTimes)
        var stats = stats
        condition.unlock()
        stats.duration = duration
        return FileTree(rootPath: rootPath, names: names, parents: parents, kinds: kinds,
                        ownSizes: ownSizes, modTimes: modTimes, stats: stats)
    }
}
