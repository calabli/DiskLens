/// The result of a scan, stored as parallel flat arrays indexed by node id
/// instead of one object per file, so millions of entries stay compact.
///
/// Node 0 is the scan root. A node is always appended after its parent, so
/// `parents[i] < i` for every `i > 0`; sizes roll up in one reverse pass.
public struct FileTree: Sendable {
    public let rootPath: String
    public let names: [String]
    public let parents: [Int32]
    public let kinds: [EntryKind]
    /// Bytes allocated by the node itself (0 for a hard link already counted elsewhere).
    public let ownSizes: [Int64]
    /// Bytes allocated by the node and everything under it.
    public let totalSizes: [Int64]
    /// Number of files at or under the node.
    public let fileCounts: [Int32]
    public let modTimes: [Int64]
    public let stats: ScanStats

    // Children in CSR form: the children of node i are
    // childIndex[childStart[i] ..< childStart[i + 1]], largest first.
    private let childStart: [Int32]
    private let childIndex: [Int32]

    public var count: Int { names.count }
    public var totalSize: Int64 { totalSizes.first ?? 0 }

    init(rootPath: String, names: [String], parents: [Int32], kinds: [EntryKind],
         ownSizes: [Int64], modTimes: [Int64], stats: ScanStats) {
        let n = names.count
        var totals = ownSizes
        var files = kinds.map { $0 == .directory ? Int32(0) : 1 }
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
        self.childIndex = index
    }

    /// Children of `node`, largest first.
    public func children(of node: Int) -> ArraySlice<Int32> {
        childIndex[Int(childStart[node])..<Int(childStart[node + 1])]
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
