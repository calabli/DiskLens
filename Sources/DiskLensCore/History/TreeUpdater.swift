import Darwin
import Foundation

/// Brings a cached tree up to date by re-reading only the folders in a
/// `ChangeSet`. Unchanged folders are copied over as they are, folders that
/// appeared are scanned, and folders that vanished are dropped, so the result
/// matches a fresh scan of the same files.
///
/// Node ids are renumbered; look nodes up again by path.
public enum TreeUpdater {
    public static func update(_ old: FileTree, applying changes: ChangeSet,
                              options: ScanOptions = ScanOptions()) throws -> FileTree {
        let started = Date()
        var st = stat()
        guard lstat(old.rootPath, &st) == 0 else { throw ScanError.cannotRead(path: old.rootPath, errno: errno) }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(path: old.rootPath) }

        var update = Update(old: old, changes: changes, options: options, rootDevice: st.st_dev)
        update.builder.addRoot(old.rootPath, ownSize: Int64(st.st_blocks) * 512, modTime: old.modTimes[0])
        try update.visit(oldNode: 0, newNode: 0, path: old.rootPath)

        var stats = update.builder.stats
        stats.unreadableDirectories += old.stats.unreadableDirectories
        stats.unreadableSamples = Array((old.stats.unreadableSamples + stats.unreadableSamples).prefix(20))
        stats.duration = Date().timeIntervalSince(started)
        return update.builder.makeTree(rootPath: old.rootPath, stats: stats)
    }
}

private struct Update {
    let old: FileTree
    let changes: ChangeSet
    let options: ScanOptions
    let rootDevice: Int32
    var builder = TreeArrays()
    private let reader = DirectoryReader()
    private var entries: [RawEntry] = []
    private var nameBytes: [UInt8] = []

    init(old: FileTree, changes: ChangeSet, options: ScanOptions, rootDevice: Int32) {
        self.old = old
        self.changes = changes
        self.options = options
        self.rootDevice = rootDevice
    }

    /// Fills in the children of `newNode`, which stands for `oldNode` at `path`.
    mutating func visit(oldNode: Int, newNode: Int32, path: String) throws {
        if changes.subtrees.contains(path) {
            graftFreshScan(of: path, under: newNode)
        } else if changes.folders.contains(path), reread(path, oldNode: oldNode, newNode: newNode) {
            return
        } else {
            for child in old.children(of: oldNode).map(Int.init) {
                let node = builder.add(nameOf: child, in: old.names, parent: newNode, kind: old.kinds[child],
                                       ownSize: old.ownSizes[child], modTime: old.modTimes[child])
                if old.kinds[child] == .directory {
                    try visit(oldNode: child, newNode: node, path: Self.join(path, old.names[child]))
                }
            }
        }
    }

    /// Lists `path` again and rebuilds its children from what is there now.
    /// Returns false if it cannot be read, so the caller keeps the old contents.
    private mutating func reread(_ path: String, oldNode: Int, newNode: Int32) -> Bool {
        let fd = open(path, DirectoryReader.openFlags)
        guard fd >= 0 else { return false }
        entries.removeAll(keepingCapacity: true)
        nameBytes.removeAll(keepingCapacity: true)
        let code = reader.read(directory: fd, into: &entries, names: &nameBytes)
        close(fd)
        guard code == 0 else { return false }

        var oldFolders: [String: Int] = [:]
        for child in old.children(of: oldNode).map(Int.init) where old.kinds[child] == .directory {
            oldFolders[old.names[child]] = child
        }
        let current = (entries, nameBytes)
        for entry in current.0 {
            let name = current.1[entry.name]
            if entry.kind == .directory && options.stayOnVolume && entry.device != rootDevice {
                builder.stats.skippedMounts += 1
                continue
            }
            let node = name.withUnsafeBufferPointer {
                builder.add(name: $0, parent: newNode, kind: entry.kind, ownSize: entry.allocSize, modTime: entry.modTime)
            }
            guard entry.kind == .directory else { continue }
            let childName = String(decoding: name, as: UTF8.self)
            let childPath = Self.join(path, childName)
            if let oldChild = oldFolders[childName] {
                try? visit(oldNode: oldChild, newNode: node, path: childPath)
            } else {
                graftFreshScan(of: childPath, under: node)
            }
        }
        return true
    }

    /// Scans `path` from scratch and adds everything in it below `newNode`.
    private mutating func graftFreshScan(of path: String, under newNode: Int32) {
        guard let fresh = try? DiskScanner(options: options).scan(path) else { return }
        var ids = [Int32](repeating: newNode, count: fresh.count)
        for node in 1..<max(fresh.count, 1) {
            ids[node] = builder.add(nameOf: node, in: fresh.names, parent: ids[Int(fresh.parents[node])],
                                    kind: fresh.kinds[node], ownSize: fresh.ownSizes[node],
                                    modTime: fresh.modTimes[node])
        }
        builder.stats.unreadableDirectories += fresh.stats.unreadableDirectories
        builder.stats.skippedMounts += fresh.stats.skippedMounts
    }

    private static func join(_ path: String, _ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }
}

/// The per-entry arrays of a tree under construction, parents always first.
private struct TreeArrays {
    var names = NamePool()
    var parents = ChunkedArray<Int32>()
    var kinds = ChunkedArray<EntryKind>()
    var ownSizes = ChunkedArray<Int64>()
    var modTimes = ChunkedArray<Int64>()
    var stats = ScanStats()

    mutating func addRoot(_ path: String, ownSize: Int64, modTime: Int64) {
        names.append(path)
        parents.append(-1)
        kinds.append(.directory)
        ownSizes.append(ownSize)
        modTimes.append(modTime)
        stats.directories += 1
    }

    mutating func add(name: UnsafeBufferPointer<UInt8>, parent: Int32, kind: EntryKind,
                      ownSize: Int64, modTime: Int64) -> Int32 {
        names.append(bytes: name)
        return finishAdding(parent: parent, kind: kind, ownSize: ownSize, modTime: modTime)
    }

    mutating func add(nameOf node: Int, in pool: NamePool, parent: Int32, kind: EntryKind,
                      ownSize: Int64, modTime: Int64) -> Int32 {
        names.append(node, of: pool)
        return finishAdding(parent: parent, kind: kind, ownSize: ownSize, modTime: modTime)
    }

    private mutating func finishAdding(parent: Int32, kind: EntryKind, ownSize: Int64, modTime: Int64) -> Int32 {
        parents.append(parent)
        kinds.append(kind)
        ownSizes.append(ownSize)
        modTimes.append(modTime)
        if kind == .directory { stats.directories += 1 } else { stats.files += 1 }
        return Int32(parents.count - 1)
    }

    func makeTree(rootPath: String, stats: ScanStats) -> FileTree {
        FileTree(rootPath: rootPath, names: names, parents: parents, kinds: kinds,
                 ownSizes: ownSizes, modTimes: modTimes, stats: stats)
    }
}
