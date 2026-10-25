/// The result of a scan, stored as parallel flat arrays indexed by node id
/// instead of one object per file, so millions of entries stay compact.
///
/// Node 0 is the scan root. A node is always appended after its parent, so
/// `parents[i] < i` for every `i > 0`; sizes roll up in one reverse pass.
public struct FileTree: Sendable {
    public let rootPath: String
    // Written once by the scanner and shared, not copied, between snapshots.
    public let names: NamePool
    public let parents: ChunkedArray<Int32>
    public let kinds: ChunkedArray<EntryKind>
    /// Bytes allocated by the node itself (0 for a hard link already counted elsewhere).
    public let ownSizes: ChunkedArray<Int64>
    /// Bytes allocated by the node and everything under it.
    public private(set) var totalSizes: [Int64]
    /// Number of files at or under the node.
    public private(set) var fileCounts: [Int32]
    public let modTimes: ChunkedArray<Int64>
    public let stats: ScanStats

    // Children in CSR form: the live children of node i are
    // childIndex[childStart[i] ..< childEnd[i]], largest first.
    private let childStart: [Int32]
    private var childEnd: [Int32]
    private var childIndex: [Int32]
    private var removed: [Bool]

    public var count: Int { names.count }
    public var totalSize: Int64 { totalSizes.first ?? 0 }

    init(rootPath: String, names: NamePool, parents: ChunkedArray<Int32>, kinds: ChunkedArray<EntryKind>,
         ownSizes: ChunkedArray<Int64>, modTimes: ChunkedArray<Int64>, stats: ScanStats) {
        let n = names.count
        var totals = [Int64](repeating: 0, count: n)
        var files = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            totals[i] = ownSizes[i]
            files[i] = kinds[i] == .directory ? 0 : 1
        }
        for i in stride(from: n - 1, to: 0, by: -1) {
            let p = Int(parents[i])
            totals[p] += totals[i]
            files[p] += files[i]
        }

        var start = [Int32](repeating: 0, count: n + 1)
        for i in 1..<max(n, 1) { start[Int(parents[i]) + 1] += 1 }
        for i in 0..<n { start[i + 1] += start[i] }
        var fill = start
        var index = [Int32](repeating: 0, count: max(n - 1, 0))
        for i in 1..<max(n, 1) {
            let p = Int(parents[i])
            index[Int(fill[p])] = Int32(i)
            fill[p] += 1
        }
        for i in 0..<n where start[i + 1] - start[i] > 1 {
            index[Int(start[i])..<Int(start[i + 1])].sort { totals[Int($0)] > totals[Int($1)] }
        }

        self.rootPath = rootPath
        self.names = names
        self.parents = parents
        self.kinds = kinds
        self.ownSizes = ownSizes
        self.totalSizes = totals
        self.fileCounts = files
        self.modTimes = modTimes
        self.stats = stats
        self.childStart = start
        self.childEnd = Array(start.dropFirst())
        self.childIndex = index
        self.removed = [Bool](repeating: false, count: n)
    }

    /// Children of `node`, largest first.
    public func children(of node: Int) -> ArraySlice<Int32> {
        childIndex[Int(childStart[node])..<Int(childEnd[node])]
    }

    /// Absolute path of `node`.
    public func path(of node: Int) -> String {
        var parts: [String] = []
        var i = node
        while i > 0 {
            parts.append(names[i])
            i = Int(parents[i])
        }
        guard !parts.isEmpty else { return rootPath }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    /// The node at `path`, if the tree has it (not removed).
    public func node(atPath path: String) -> Int? {
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        guard path == base || path.hasPrefix(base + "/") || base.isEmpty else { return nil }
        var node = 0
        for part in path.dropFirst(base.count).split(separator: "/") {
            guard let next = children(of: node).first(where: { names[Int($0)] == part }) else { return nil }
            node = Int(next)
        }
        return node
    }

    /// Whether `ancestor` is `node` itself or one of the folders containing it.
    public func isAncestor(_ ancestor: Int, of node: Int) -> Bool {
        var i = node
        while i >= 0 {
            if i == ancestor { return true }
            i = i == 0 ? -1 : Int(parents[i])
        }
        return false
    }

    /// Whether `node` itself was removed (not counting its folders).
    func isRemovedItself(_ node: Int) -> Bool {
        removed[node]
    }

    /// Whether `node` or a folder containing it was removed with `remove(_:)`.
    public func isRemoved(_ node: Int) -> Bool {
        var i = node
        while i > 0 {
            if removed[i] { return true }
            i = Int(parents[i])
        }
        return false
    }

    /// Takes `node` and everything under it out of the tree, as after moving it
    /// to the Trash: ancestors shrink and stay sorted largest first.
    @discardableResult
    public mutating func remove(_ node: Int) -> Bool {
        guard node > 0, node < count, !isRemoved(node) else { return false }
        let size = totalSizes[node]
        let files = fileCounts[node]
        let parent = Int(parents[node])

        let lower = Int(childStart[parent])
        let upper = Int(childEnd[parent])
        if let pos = childIndex[lower..<upper].firstIndex(of: Int32(node)) {
            for k in pos..<(upper - 1) { childIndex[k] = childIndex[k + 1] }
            childEnd[parent] -= 1
        }
        removed[node] = true

        var a = parent
        while true {
            totalSizes[a] -= size
            fileCounts[a] -= files
            if a == 0 { break }
            moveTowardEnd(a)
            a = Int(parents[a])
        }
        return true
    }

    /// Restores largest-first order among `node`'s siblings after `node` shrank.
    private mutating func moveTowardEnd(_ node: Int) {
        let parent = Int(parents[node])
        let lower = Int(childStart[parent])
        let upper = Int(childEnd[parent])
        guard var pos = childIndex[lower..<upper].firstIndex(of: Int32(node)) else { return }
        while pos + 1 < upper && totalSizes[Int(childIndex[pos + 1])] > totalSizes[node] {
            childIndex.swapAt(pos, pos + 1)
            pos += 1
        }
    }
}

public struct ScanStats: Sendable {
    public var files = 0
    public var directories = 0
    /// Directories that could not be read (usually missing Full Disk Access).
    public var unreadableDirectories = 0
    public var unreadableSamples: [String] = []
    /// Directories skipped because they are on another volume.
    public var skippedMounts = 0
    /// Hard links not counted again because their inode was already seen.
    public var duplicateHardLinks = 0
    public var duration: Double = 0
}
