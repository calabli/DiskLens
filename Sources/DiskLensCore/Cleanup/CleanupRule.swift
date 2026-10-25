import Foundation

/// How sure we are that deleting something is harmless. Drives which tier a
/// suggestion appears in and whether it can be added in bulk.
public enum CleanupSafety: String, Codable, Sendable, CaseIterable, Comparable {
    /// Rebuilt or re-downloaded automatically; nothing personal is lost.
    case safe
    /// Probably not needed, but the user should look before deleting.
    case review
    /// Worth knowing about, but must not be deleted as files (use a command or leave it).
    case info

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public enum CleanupCategory: String, Codable, Sendable {
    case developer
    case system
    case apps
    case chat
    case backups
    case projects
    case leftovers
}

public enum CleanupAction: String, Codable, Sendable {
    /// Items can go to the basket and from there to the Trash.
    case trash
    /// Clean up with the shown command instead of deleting files.
    case command
    /// Nothing to do in DiskLens; the explanation says what to do.
    case none
}

/// One entry of the rule library: where a known kind of reclaimable data lives
/// and what deleting it means.
public struct CleanupRule: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: CleanupCategory
    public let safety: CleanupSafety
    /// Comes back on its own (a cache, a download) rather than being lost.
    public let regenerable: Bool
    public let explanation: String
    /// What happens after deleting, in the user's terms.
    public let consequence: String
    /// Paths starting with `~/`; each component may be a shell-style pattern (`*`, `*.dmg`).
    public let paths: [String]
    /// Apps that own this data; cleaning waits until they are quit.
    public let apps: [String]?
    public let action: CleanupAction?
    public let command: String?
    /// Smallest total worth mentioning, in bytes.
    public let minimumSize: Int64?
}

public struct CleanupRuleSet: Codable, Sendable {
    public let version: Int
    public let rules: [CleanupRule]

    public init(data: Data) throws {
        self = try JSONDecoder().decode(CleanupRuleSet.self, from: data)
    }

    /// The rule library shipped with the app.
    public static func bundled() throws -> CleanupRuleSet {
        guard let url = Bundle.module.url(forResource: "cleanup-rules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try CleanupRuleSet(data: Data(contentsOf: url))
    }
}

/// Something the user can act on, found by a rule or a heuristic.
public struct CleanupItem: Sendable, Identifiable, Hashable {
    public let node: Int
    public let size: Int64
    /// What to call it, e.g. "my-app/node_modules" or "com.example.App · 缓存".
    public let label: String
    /// Last change, where it explains why the item is suggested.
    public let lastModified: Date?

    public var id: Int { node }
}

public struct CleanupSuggestion: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: CleanupCategory
    public let safety: CleanupSafety
    public let regenerable: Bool
    public let explanation: String
    public let consequence: String
    public let action: CleanupAction
    public let command: String?
    public let apps: [String]
    /// Largest first.
    public let items: [CleanupItem]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Higher first: big, safe, regenerable things are the best bets.
    public var score: Double {
        let safetyWeight: Double = switch safety {
        case .safe: 1
        case .review: 0.5
        case .info: 0.1
        }
        return Double(totalSize) * safetyWeight * (regenerable ? 1 : 0.6)
    }
}
