import Foundation

/// A family of developer tools DiskLens knows how to look after.
public enum DevEcosystem: String, CaseIterable, Sendable {
    case apple, docker, homebrew, java, go

    public var title: String {
        switch self {
        case .apple: "Xcode 与模拟器"
        case .docker: "Docker"
        case .homebrew: "Homebrew"
        case .java: "Java"
        case .go: "Go"
        }
    }
}

/// One installed toolchain, SDK, simulator, image or cache, with what it takes
/// and how it can be removed.
public struct DevItem: Sendable, Identifiable {
    public enum Usage: Sendable, Equatable {
        /// The default or running one: removing it breaks the current setup.
        case active(String)
        /// Something still refers to it, e.g. "2 个项目在用".
        case used(String)
        /// Nothing refers to it any more, e.g. "项目已不存在".
        case unused(String)
        /// A cache: may well be in use, but comes back on its own when removed.
        case regenerable(String)
        case unknown
    }

    public enum Removal: Sendable, Equatable {
        /// The tool's own command, which also updates the tool's records.
        case command(ToolCommand)
        /// A plain folder or file, moved to the Trash through the basket.
        case trash(String)
        /// Cannot be removed from DiskLens; the text says what to do instead.
        case none(String)
    }

    public let id: String
    public let ecosystem: DevEcosystem
    /// What it is, e.g. "模拟器", "JDK", "镜像".
    public let kind: String
    public let title: String
    /// A version, a path or a short note.
    public let detail: String?
    public let path: String?
    /// Bytes on disk; nil until measured.
    public var size: Int64?
    public let lastUsed: Date?
    public let usage: Usage
    public let removal: Removal
    /// What removing it means, shown before anything is removed.
    public let consequence: String

    public init(id: String, ecosystem: DevEcosystem, kind: String, title: String, detail: String? = nil,
                path: String? = nil, size: Int64? = nil, lastUsed: Date? = nil, usage: Usage = .unknown,
                removal: Removal, consequence: String) {
        self.id = id
        self.ecosystem = ecosystem
        self.kind = kind
        self.title = title
        self.detail = detail
        self.path = path
        self.size = size
        self.lastUsed = lastUsed
        self.usage = usage
        self.removal = removal
        self.consequence = consequence
    }
}

/// Everything found for one ecosystem.
public struct DevGroup: Sendable, Identifiable {
    public let ecosystem: DevEcosystem
    public var items: [DevItem]
    /// Said above the items, e.g. that Docker is not running.
    public var note: String?

    public var id: DevEcosystem { ecosystem }
    public var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
}

/// What detectors need from the outside world, so tests can stand in for it.
public struct DevContext: Sendable {
    public var home: String
    /// The current scan, for sizes and for finding project files without reading the disk again.
    public var tree: FileTree?
    public var run: @Sendable (ToolCommand, TimeInterval) -> ToolCommand.Result?

    public init(home: String = UserHome.path, tree: FileTree? = nil,
                run: @escaping @Sendable (ToolCommand, TimeInterval) -> ToolCommand.Result? = { try? $0.run(timeout: $1) }) {
        self.home = home
        self.tree = tree
        self.run = run
    }

    /// Standard output of a command that succeeded, or nil.
    func output(_ program: String, _ arguments: [String], timeout: TimeInterval = 30) -> String? {
        let command = ToolCommand(program, arguments)
        guard command.isInstalled, let result = run(command, timeout), result.succeeded else { return nil }
        return result.output
    }

    /// Bytes allocated under `path`: from the scan when it covers the path, else measured now.
    func size(of path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if let tree, let node = tree.node(atPath: path) { return tree.totalSizes[node] }
        if st.st_mode & S_IFMT != S_IFDIR { return Int64(st.st_blocks) * 512 }
        return (try? DiskScanner().scan(path))?.totalSize
    }

    func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func subfolders(of path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { path + "/" + $0 }
            .filter { var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
    }

    /// Files named `name` anywhere in the current scan (none without a scan).
    func filesInScan(named name: String) -> [String] {
        guard let tree else { return [] }
        var found: [String] = []
        for node in 1..<max(tree.count, 1) where tree.kinds[node] == .file && tree.names[node] == name && !tree.isRemoved(node) {
            found.append(tree.path(of: node))
        }
        return found
    }
}

/// Finds the installed developer tools on this Mac, one ecosystem at a time.
public enum DevEnvironmentScanner {
    public static func discover(_ ecosystem: DevEcosystem, context: DevContext) -> DevGroup {
        var group = switch ecosystem {
        case .apple: AppleTools.discover(context)
        case .docker: DockerTools.discover(context)
        case .homebrew: HomebrewTools.discover(context)
        case .java: JavaTools.discover(context)
        case .go: GoTools.discover(context)
        }
        group.items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        return group
    }

    /// Sizes such as "1.21GB", "567MB", "12.3kB" or "0B", as Docker and Homebrew print them (powers of 1000).
    public static func parseSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let range = trimmed.range(of: #"^[0-9.]+"#, options: .regularExpression),
              let number = Double(trimmed[range]) else { return nil }
        let unit = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces).uppercased()
        let scale: Double = switch unit {
        case "B", "": 1
        case "KB", "K": 1e3
        case "MB", "M": 1e6
        case "GB", "G": 1e9
        case "TB", "T": 1e12
        default: -1
        }
        return scale < 0 ? nil : Int64(number * scale)
    }
}
