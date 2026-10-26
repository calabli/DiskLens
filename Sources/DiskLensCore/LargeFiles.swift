import CoreServices
import Foundation

public struct LargeFile: Sendable, Identifiable, Hashable {
    public let node: Int
    public let name: String
    public let size: Int64
    public let category: FileCategory
    public let modified: Date
    /// The folder it is in, with the home folder shown as `~`.
    public let location: String
    /// Inside ~/Library, where files usually belong to an app rather than to the user.
    public let isAppData: Bool

    public var id: Int { node }
}

public enum LargeFileFinder {
    /// The largest files in `tree`, largest first. Files inside app bundles,
    /// photo libraries and disk-image bundles are left out: deleting one of
    /// them breaks the bundle, so the bundle as a whole is listed instead.
    public static func find(in tree: FileTree, minimumSize: Int64, limit: Int = 2_000,
                            homePath: String = UserHome.path) -> [LargeFile] {
        var candidates: [Int] = []
        for node in 1..<max(tree.count, 1) where tree.totalSizes[node] >= minimumSize {
            switch tree.kinds[node] {
            case .file:
                candidates.append(node)
            case .directory where FileCategory.of(name: tree.names[node], kind: .directory).isOpaqueBundle:
                candidates.append(node)
            default:
                continue
            }
        }
        candidates.sort { tree.totalSizes[$0] > tree.totalSizes[$1] }

        var result: [LargeFile] = []
        for node in candidates where !isInsideBundle(node, in: tree) && !tree.isRemoved(node) {
            let location = location(of: node, in: tree, homePath: homePath)
            result.append(LargeFile(
                node: node, name: tree.names[node], size: tree.totalSizes[node],
                category: FileCategory.of(name: tree.names[node], kind: tree.kinds[node]),
                modified: Date(timeIntervalSince1970: TimeInterval(tree.modTimes[node])),
                location: location,
                isAppData: location == "~/Library" || location.hasPrefix("~/Library/")))
            if result.count == limit { break }
        }
        return result
    }

    private static func isInsideBundle(_ node: Int, in tree: FileTree) -> Bool {
        var i = Int(tree.parents[node])
        while i > 0 {
            if FileCategory.of(name: tree.names[i], kind: tree.kinds[i]).isOpaqueBundle { return true }
            i = Int(tree.parents[i])
        }
        return false
    }

    /// The folder `node` is in, as people know it: the home folder as `~`,
    /// without the data volume's /System/Volumes/Data prefix.
    static func location(of node: Int, in tree: FileTree, homePath: String) -> String {
        let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        let parentPath = logicalPath(tree.path(of: Int(tree.parents[node])))
        return parentPath == home || parentPath.hasPrefix(home + "/")
            ? "~" + parentPath.dropFirst(home.count) : parentPath
    }

    private static func logicalPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        return path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path
    }

    /// When the file was last opened, according to Spotlight, or nil where
    /// Spotlight does not track it (unindexed folders, files never opened).
    public static func lastUsedDate(ofFileAt path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
