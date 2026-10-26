import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Do not descend into directories on another volume.
    public var stayOnVolume = true
    /// Scanning waits mostly on small random metadata reads from the SSD, so it
    /// keeps speeding up with more reads in flight than there are cores.
    public var threadCount = min(max(ProcessInfo.processInfo.activeProcessorCount * 4, 4), 32)

    /// Most folders kept open at once for opening subfolders by name (nil: as many as
    /// the system allows). Beyond it, folders are opened by full path.
    public var openFolderLimit: Int?

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
                                  stayOnVolume: options.stayOnVolume, workers: options.threadCount,
                                  openFolderLimit: options.openFolderLimit, progress: progress)
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

/// An open folder kept so its subfolders can be opened by name with `openat`,
/// instead of each lookup walking the full path from `/`. With many threads,
/// those full-path walks contend on the same top folders and cost more than
/// reading the folders themselves. Closed when the last subfolder is opened.
private final class DirectoryHandle: @unchecked Sendable {
    let fd: Int32
    private let budget: FileBudget

    init(fd: Int32, budget: FileBudget) {
        self.fd = fd
        self.budget = budget
    }

    deinit {
        close(fd)
        budget.release()
    }
}

/// How many folders may be held open at once; past it, folders are opened by path.
private final class FileBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int

    init(_ count: Int) {
        available = count
    }

    func take() -> Bool {
        lock.withLock {
            guard available > 0 else { return false }
            available -= 1
            return true
        }
    }

    func release() {
        lock.withLock { available += 1 }
    }

    /// Lets this process keep more folders open, up to the system's per-process limit.
    static func raisedProcessLimit(workers: Int) -> FileBudget {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX))
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            setrlimit(RLIMIT_NOFILE, &limit)
            getrlimit(RLIMIT_NOFILE, &limit)
        }
        // Leave room for everything else the process has open, plus each worker's current folder.
        let spare = Int(limit.rlim_cur) - 256 - workers
        return FileBudget(min(max(spare, 0), 8_192))
    }
}

private struct Job {
    var node: Int32
    var path: String
    var depth: Int32
    /// The folder's own name, for opening it relative to `parent`.
    var name: String
    var parent: DirectoryHandle?
}

private final class TreeBuilder: @unchecked Sendable {
    /// Folders this shallow are read breadth-first, so a live view sees the whole
    /// top of the tree early; deeper ones depth-first, which keeps few folders open.
    private static let breadthFirstDepth: Int32 = 3

    private let condition = NSCondition()
    private let rootPath: String
    private let rootDevice: Int32
    private let stayOnVolume: Bool
    private let progress: (@Sendable (Int) -> Void)?
    private let budget: FileBudget

    // Guarded by `condition`.
    private var names = NamePool()
    private var parents: ChunkedArray<Int32> = [-1]
    private var kinds: ChunkedArray<EntryKind> = [.directory]
    private var ownSizes = ChunkedArray<Int64>()
    private var modTimes: ChunkedArray<Int64> = [0]
    private var shallow: [Job]
    private var shallowHead = 0
    private var deep: [Job] = []
    private var pending = 1
    private var seenHardLinks = Set<UInt64>()
    private(set) var stats = ScanStats()
    private(set) var rootError: Int32?
    private(set) var isCancelled = false
    /// Signaled once, when the last queued directory has been read.
    private let finished = DispatchSemaphore(value: 0)

    init(rootPath: String, rootDevice: Int32, rootSize: Int64, stayOnVolume: Bool, workers: Int,
         openFolderLimit: Int?, progress: (@Sendable (Int) -> Void)?) {
        self.rootPath = rootPath
        self.rootDevice = rootDevice
        self.stayOnVolume = stayOnVolume
        self.progress = progress
        budget = openFolderLimit.map(FileBudget.init) ?? FileBudget.raisedProcessLimit(workers: workers)
        names.append(rootPath)
        ownSizes.append(rootSize)
        shallow = [Job(node: 0, path: rootPath, depth: 0, name: rootPath, parent: nil)]
    }

    func work() {
        let reader = DirectoryReader()
        var entries: [RawEntry] = []
        var nameBytes: [UInt8] = []
        while let job = nextJob() {
            entries.removeAll(keepingCapacity: true)
            nameBytes.removeAll(keepingCapacity: true)
            let fd = if let parent = job.parent {
                openat(parent.fd, job.name, DirectoryReader.openFlags)
            } else {
                open(job.path, DirectoryReader.openFlags)
            }
            var code = fd < 0 ? errno : 0
            var handle: DirectoryHandle?
            if fd >= 0 {
                code = reader.read(directory: fd, into: &entries, names: &nameBytes)
                let hasSubfolders = entries.contains { $0.kind == .directory }
                if code == 0 && hasSubfolders && budget.take() {
                    handle = DirectoryHandle(fd: fd, budget: budget)
                } else {
                    close(fd)
                }
            }
            finish(job, entries: entries, names: nameBytes, error: code, handle: handle)
        }
    }

    /// Returns once every queued directory has been read; idle workers exit on their own.
    func waitUntilDone() {
        finished.wait()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        pending -= (shallow.count - shallowHead) + deep.count
        shallow.removeAll()
        shallowHead = 0
        deep.removeAll()
        if pending == 0 { finished.signal() }
        condition.broadcast()
        condition.unlock()
    }

    private func nextJob() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while shallowHead == shallow.count && deep.isEmpty {
            if pending == 0 { return nil }
            condition.wait()
        }
        if shallowHead < shallow.count {
            let job = shallow[shallowHead]
            // Drop this slot's references (path, parent handle) now rather than at compaction.
            shallow[shallowHead] = Job(node: -1, path: "", depth: 0, name: "", parent: nil)
            shallowHead += 1
            if shallowHead >= 4096 && shallowHead * 2 >= shallow.count {
                shallow.removeFirst(shallowHead)
                shallowHead = 0
            }
            return job
        }
        return deep.removeLast()
    }

    private func finish(_ job: Job, entries: [RawEntry], names nameBytes: [UInt8], error: Int32,
                        handle: DirectoryHandle?) {
        var newJobs = 0
        condition.lock()
        defer {
            pending -= 1
            if pending == 0 {
                // Everything is read: let every idle worker see that and exit.
                finished.signal()
                condition.broadcast()
            } else {
                // Wake one idle worker per new folder instead of all of them;
                // waking every thread for every folder was most of the kernel time.
                for _ in 0..<min(newJobs, 64) { condition.signal() }
            }
            condition.unlock()
        }

        if isCancelled { return }
        stats.directories += 1
        if error != 0 {
            if job.node == 0 { rootError = error }
            stats.noteUnreadable(job.path, code: error)
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
                let childName = String(decoding: name, as: UTF8.self)
                let child = Job(node: node, path: prefix + childName, depth: job.depth + 1,
                                name: childName, parent: handle)
                if child.depth <= Self.breadthFirstDepth {
                    shallow.append(child)
                } else {
                    deep.append(child)
                }
                pending += 1
                newJobs += 1
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
