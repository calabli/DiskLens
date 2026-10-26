import Foundation

/// A file or folder whose name matched a search.
public struct NameMatch: Sendable, Identifiable, Hashable {
    public let node: Int
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let category: FileCategory
    public let modified: Date
    /// The folder it is in, with the home folder shown as `~`.
    public let location: String

    public var id: Int { node }
}

public struct NameSearchResult: Sendable {
    /// The largest matches, largest first.
    public let matches: [NameMatch]
    /// How many items matched in all, including those not listed.
    public let total: Int
}

/// Finds files and folders by name across a whole scan.
public enum NameSearch {
    /// Items whose name contains `query`, ignoring case, largest first.
    /// Returns nil if the task is cancelled while searching.
    public static func find(_ query: String, in tree: FileTree, limit: Int = 500,
                            homePath: String = UserHome.path) -> NameSearchResult? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, tree.count > 1 else { return NameSearchResult(matches: [], total: 0) }

        let matcher = Matcher(query)
        var hits: [Int] = []
        for node in 1..<tree.count {
            if node & 0xFFFF == 0 && Task.isCancelled { return nil }
            if tree.names.withUTF8(node, matcher.matches) && !tree.isRemoved(node) { hits.append(node) }
        }
        hits.sort { tree.totalSizes[$0] > tree.totalSizes[$1] }

        let matches = hits.prefix(limit).map { node in
            NameMatch(node: node, name: tree.names[node], size: tree.totalSizes[node],
                      isDirectory: tree.kinds[node] == .directory,
                      category: FileCategory.of(name: tree.names[node], kind: tree.kinds[node]),
                      modified: Date(timeIntervalSince1970: TimeInterval(tree.modTimes[node])),
                      location: LargeFileFinder.location(of: node, in: tree, homePath: homePath))
        }
        return NameSearchResult(matches: matches, total: hits.count)
    }
}

/// Case-insensitive substring matching straight on a name's UTF-8 bytes.
/// An ASCII query is compared byte by byte, which covers most searches without
/// making a `String` per name; any other query (Chinese, accented letters) is
/// compared as text, and only against names that contain non-ASCII bytes.
private struct Matcher {
    private let ascii: [UInt8]?
    private let text: String

    init(_ query: String) {
        text = query
        ascii = query.utf8.allSatisfy { $0 < 0x80 } ? query.utf8.map(Self.lower) : nil
    }

    func matches(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        if let ascii { return Self.contains(name, ascii) }
        guard name.contains(where: { $0 >= 0x80 }) else { return false }
        return String(decoding: name, as: UTF8.self).localizedStandardContains(text)
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard haystack.count >= n else { return false }
        let first = needle[0]
        for start in 0...(haystack.count - n) where lower(haystack[start]) == first {
            var i = 1
            while i < n && lower(haystack[start + i]) == needle[i] { i += 1 }
            if i == n { return true }
        }
        return false
    }
}
