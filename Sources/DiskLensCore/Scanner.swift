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

    public var description: String {
        switch self {
        case let .cannotRead(path, code): "cannot read \(path): \(String(cString: strerror(code)))"
        case let .notADirectory(path): "\(path) is not a directory"
        }
    }
}

/// Walks a directory tree on several threads. Each thread reads whole directories
/// with `DirectoryReader` and hands the entries to a shared builder under a lock.
public final class Scanner: @unchecked Sendable {
    public let options: ScanOptions
    private let progress: (@Sendable (_ filesSoFar: Int) -> Void)?

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
        threads.forEach { $0.stackSize = 1 << 20; $0.start() }
        builder.waitUntilDone()

        if builder.stats.directories == 0, let code = builder.rootError {
            throw ScanError.cannotRead(path: rootPath, errno: code)
        }
        return builder.makeTree(duration: Date().timeIntervalSince(started))
    }
}

private final class TreeBuilder: @unchecked Sendable {
    private let condition = NSCondition()
    private let rootPath: String
    private let rootDevice: Int32
    private let stayOnVolume: Bool
    private let progress: (@Sendable (Int) -> Void)?

    // Guarded by `condition`.
    private var names: [String]
    private var parents: [Int32] = [-1]
    private var kinds: [EntryKind] = [.directory]
    private var ownSizes: [Int64]
    private var modTimes: [Int64] = [0]
    private var queue: [(node: Int32, path: String)]
    private var pending = 1
    private var seenHardLinks = Set<UInt64>()
    private(set) var stats = ScanStats()
    private(set) var rootError: Int32?

    init(rootPath: String, rootDevice: Int32, rootSize: Int64, stayOnVolume: Bool,
         progress: (@Sendable (Int) -> Void)?) {
        self.rootPath = rootPath
        self.rootDevice = rootDevice
        self.stayOnVolume = stayOnVolume
        self.progress = progress
        names = [rootPath]
        ownSizes = [rootSize]
        queue = [(0, rootPath)]
    }

    func work() {
        let reader = DirectoryReader()
        var entries: [RawEntry] = []
        while let job = nextJob() {
            entries.removeAll(keepingCapacity: true)
            let code = reader.read(path: job.path, into: &entries)
            finish(job, entries: entries, error: code)
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

    private func nextJob() -> (node: Int32, path: String)? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty {
            if pending == 0 { return nil }
            condition.wait()
        }
        return queue.removeLast()
    }

    private func finish(_ job: (node: Int32, path: String), entries: [RawEntry], error: Int32) {
        condition.lock()
        defer {
            pending -= 1
            condition.broadcast()
            condition.unlock()
        }

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
            names.append(entry.name)
            parents.append(job.node)
            kinds.append(entry.kind)
            ownSizes.append(size)
            modTimes.append(entry.modTime)

            if entry.kind == .directory {
                queue.append((node, prefix + entry.name))
                pending += 1
            }
        }

        if let progress, stats.directories % 512 == 0 {
            progress(stats.files)
        }
    }

    func makeTree(duration: Double) -> FileTree {
        condition.lock()
        defer { condition.unlock() }
        var stats = stats
        stats.duration = duration
        return FileTree(rootPath: rootPath, names: names, parents: parents, kinds: kinds,
                        ownSizes: ownSizes, modTimes: modTimes, stats: stats)
    }
}
