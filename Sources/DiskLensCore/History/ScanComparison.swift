import Foundation

public struct ScanChange: Sendable, Identifiable, Hashable {
    /// Full path; also the identity, since node ids differ between the two trees.
    public let path: String
    public let before: Int64
    public let after: Int64
    public let isDirectory: Bool

    public var id: String { path }
    public var delta: Int64 { after - before }
}

/// What grew and shrank between two scans of the same folder, as the most
/// specific folders or files that account for each change.
public struct ScanComparison: Sendable {
    public let previousDate: Date
    public let previousTotal: Int64
    public let currentTotal: Int64
    /// Largest change first.
    public let changes: [ScanChange]

    public var delta: Int64 { currentTotal - previousTotal }

    /// - Parameters:
    ///   - minimumChange: changes smaller than this are not listed.
    ///   - explainedShare: a folder is left out when one of its children accounts
    ///     for at least this share of its change, so the child is listed instead.
    public init(previous: FileTree, previousDate: Date, current: FileTree,
                minimumChange: Int64 = 50_000_000, explainedShare: Double = 0.8, limit: Int = 40) {
        self.previousDate = previousDate
        previousTotal = previous.totalSize
        currentTotal = current.totalSize

        let before = Self.sizes(in: previous, atLeast: minimumChange)
        let after = Self.sizes(in: current, atLeast: minimumChange)
        var candidates: [String: ScanChange] = [:]
        for path in Set(before.keys).union(after.keys) {
            let old = before[path]
            let new = after[path]
            // A path below the threshold on one side was left out of its map; look it up.
            let oldSize = old?.size ?? Self.size(of: path, in: previous)
            let newSize = new?.size ?? Self.size(of: path, in: current)
            guard abs(newSize - oldSize) >= minimumChange else { continue }
            candidates[path] = ScanChange(path: path, before: oldSize, after: newSize,
                                          isDirectory: (new ?? old)?.isDirectory ?? true)
        }

        // Inside a folder that appeared or vanished as a whole, the folder is the change;
        // its contents are not listed separately.
        func isWholeFolderChange(_ change: ScanChange) -> Bool {
            change.isDirectory && (change.before == 0 || change.after == 0)
        }
        var covered = Set<String>()
        for change in candidates.values {
            var parent = (change.path as NSString).deletingLastPathComponent
            while parent.count > current.rootPath.count {
                if let parentChange = candidates[parent], isWholeFolderChange(parentChange) {
                    covered.insert(change.path)
                    break
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        // Otherwise drop a folder when one child explains most of its change in the same direction.
        var explained = Set<String>()
        for change in candidates.values where !covered.contains(change.path) {
            let parent = (change.path as NSString).deletingLastPathComponent
            guard let parentChange = candidates[parent], parentChange.delta != 0,
                  !isWholeFolderChange(parentChange) else { continue }
            let share = Double(change.delta) / Double(parentChange.delta)
            if share >= explainedShare { explained.insert(parent) }
        }
        changes = candidates.values
            .filter { !covered.contains($0.path) && !explained.contains($0.path) && $0.path != current.rootPath }
            .sorted { abs($0.delta) > abs($1.delta) }
            .prefix(limit)
            .map { $0 }
    }

    /// Paths of everything at least `minimum` in size (smaller entries cannot change by `minimum`
    /// unless they are at least that big on the other side, where they are found).
    private static func sizes(in tree: FileTree, atLeast minimum: Int64) -> [String: (size: Int64, isDirectory: Bool)] {
        var result: [String: (Int64, Bool)] = [:]
        var stack: [(Int, String)] = [(0, tree.rootPath)]
        while let (node, path) = stack.popLast() {
            result[path] = (tree.totalSizes[node], tree.kinds[node] == .directory)
            for child in tree.children(of: node).map(Int.init) where tree.totalSizes[child] >= minimum {
                let childPath = path.hasSuffix("/") ? path + tree.names[child] : path + "/" + tree.names[child]
                stack.append((child, childPath))
            }
        }
        return result
    }

    private static func size(of path: String, in tree: FileTree) -> Int64 {
        tree.node(atPath: path).map { tree.totalSizes[$0] } ?? 0
    }
}

/// The total of each scan of a folder over time, kept for the space timeline.
public struct ScanHistory: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let date: Date
        public let rootPath: String
        public let totalSize: Int64
        public let files: Int
    }

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("history.json")
    }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Appends a scan, keeping the most recent `limit` entries.
    public func record(_ tree: FileTree, at date: Date = Date(), limit: Int = 2_000) throws {
        var all = entries()
        all.append(Entry(date: date, rootPath: tree.rootPath, totalSize: tree.totalSize, files: tree.stats.files))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(all.suffix(limit))).write(to: url, options: .atomic)
    }
}
