import Darwin
import Foundation

/// Turns a scanned tree into cleanup suggestions: rules from the library first,
/// then heuristics for what no fixed path can describe. It reads only the tree
/// in memory, so it runs in a fraction of a second and never touches the disk.
///
/// Only items inside the home folder are ever suggested.
public struct CleanupAdvisor: Sendable {
    public var homePath: String
    public var now: Date
    /// A project untouched for this long has its dependencies suggested.
    public var inactiveAfter: TimeInterval = 90 * 24 * 3600
    /// Smallest suggestion worth showing, unless its rule sets its own.
    public var minimumSuggestionSize: Int64 = 10_000_000
    /// Smallest dependency folder in an inactive project worth listing.
    public var minimumProjectItemSize: Int64 = 20_000_000
    /// Smallest piece of leftover app data worth listing.
    public var minimumLeftoverItemSize: Int64 = 1_000_000
    /// Whether a bundle identifier belongs to an app that is still installed.
    public var isAppInstalled: @Sendable (String) -> Bool

    public init(homePath: String = UserHome.path, now: Date = Date(),
                isAppInstalled: @escaping @Sendable (String) -> Bool) {
        self.homePath = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        self.now = now
        self.isAppInstalled = isAppInstalled
    }

    /// Suggestions found in `tree`, safest and largest first.
    public func suggestions(for tree: FileTree, rules: [CleanupRule]) -> [CleanupSuggestion] {
        var claimed = Set<Int>()
        var result: [CleanupSuggestion] = []
        for rule in rules {
            if let suggestion = apply(rule, to: tree, claimed: &claimed) { result.append(suggestion) }
        }
        if let projects = inactiveProjects(in: tree, claimed: &claimed) { result.append(projects) }
        if let leftovers = leftoverAppData(in: tree, claimed: claimed) { result.append(leftovers) }
        return result.sorted { ($0.safety, -$0.score) < ($1.safety, -$1.score) }
    }

    // MARK: Rules

    private func apply(_ rule: CleanupRule, to tree: FileTree, claimed: inout Set<Int>) -> CleanupSuggestion? {
        var items: [CleanupItem] = []
        for pattern in rule.paths {
            for node in nodes(matching: pattern, in: tree)
            where isUnderHome(node, in: tree) && !isClaimed(node, claimed, in: tree) {
                let size = tree.totalSizes[node]
                guard size > 0 else { continue }
                claimed.insert(node)
                items.append(CleanupItem(node: node, size: size, label: displayPath(of: node, in: tree),
                                         lastModified: nil))
            }
        }
        let suggestion = CleanupSuggestion(
            id: rule.id, title: rule.title, category: rule.category, safety: rule.safety,
            regenerable: rule.regenerable, explanation: rule.explanation, consequence: rule.consequence,
            action: rule.action ?? .trash, command: rule.command, apps: rule.apps ?? [],
            items: items.sorted { $0.size > $1.size })
        return suggestion.totalSize >= (rule.minimumSize ?? minimumSuggestionSize) ? suggestion : nil
    }

    /// Nodes whose path matches `pattern` component by component.
    func nodes(matching pattern: String, in tree: FileTree) -> [Int] {
        let absolute = pattern.hasPrefix("~/") ? homePath + pattern.dropFirst(1) : pattern
        let patternParts = absolute.split(separator: "/").map(String.init)
        let rootParts = logicalPath(tree.rootPath).split(separator: "/").map(String.init)
        // The pattern must reach below the scan root; the root itself cannot be trashed.
        guard patternParts.count > rootParts.count else { return [] }
        for (part, name) in zip(patternParts, rootParts) where !component(part, matches: name) {
            return []
        }
        var frontier = [0]
        for part in patternParts[rootParts.count...] {
            var next: [Int] = []
            for node in frontier {
                for child in tree.children(of: node) where component(part, matches: tree.names[Int(child)]) {
                    next.append(Int(child))
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return frontier
    }

    private func component(_ pattern: String, matches name: String) -> Bool {
        if !pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) { return pattern == name }
        return fnmatch(pattern, name, 0) == 0
    }

    // MARK: Inactive projects

    /// Dependency and build folders, and the files that mark their folder as a project.
    static let dependencyFolders: [String: Set<String>] = [
        "node_modules": ["package.json"],
        ".next": ["package.json"],
        ".nuxt": ["package.json"],
        ".turbo": ["package.json"],
        "target": ["Cargo.toml", "pom.xml"],
        "Pods": ["Podfile"],
        ".build": ["Package.swift"],
        ".venv": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
        "venv": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"],
        ".gradle": ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
        "build": ["build.gradle", "build.gradle.kts"],
    ]

    private func inactiveProjects(in tree: FileTree, claimed: inout Set<Int>) -> CleanupSuggestion? {
        let folders = Self.dependencyFolders
        var lastActivity: [Int: Int64] = [:]
        var items: [CleanupItem] = []
        let cutoff = Int64(now.timeIntervalSince1970 - inactiveAfter)

        for node in 1..<tree.count where tree.kinds[node] == .directory {
            guard let manifests = folders[tree.names[node]] else { continue }
            let project = Int(tree.parents[node])
            let hasManifest = tree.children(of: project).contains {
                tree.kinds[Int($0)] != .directory && manifests.contains(tree.names[Int($0)])
            }
            guard hasManifest, isUserProject(project, in: tree), !isClaimed(node, claimed, in: tree) else { continue }
            let size = tree.totalSizes[node]
            guard size >= minimumProjectItemSize else { continue }

            let last = lastActivity[project] ?? newestChange(in: project, of: tree, skipping: folders)
            lastActivity[project] = last
            guard last < cutoff else { continue }
            claimed.insert(node)
            items.append(CleanupItem(node: node, size: size,
                                     label: tree.names[project] + "/" + tree.names[node],
                                     lastModified: Date(timeIntervalSince1970: TimeInterval(last))))
        }

        let suggestion = CleanupSuggestion(
            id: "heuristic.inactive-projects",
            title: "不活跃项目的依赖和构建产物",
            category: .projects, safety: .safe, regenerable: true,
            explanation: "超过 \(Int(inactiveAfter / 86_400)) 天没有改动的项目里的 node_modules、target、Pods、.venv 等目录。",
            consequence: "回到项目时重新执行 npm install、cargo build 等命令即可恢复。",
            action: .trash, command: nil, apps: [],
            items: items.sorted { $0.size > $1.size })
        return suggestion.totalSize >= minimumSuggestionSize ? suggestion : nil
    }

    /// A project the user made: inside home, not in Library, a hidden folder,
    /// an app bundle, Go's module cache, or another project's dependencies.
    private func isUserProject(_ project: Int, in tree: FileTree) -> Bool {
        guard isUnderHome(project, in: tree) else { return false }
        let relative = logicalPath(tree.path(of: project)).dropFirst(homePath.count)
        let parts = relative.split(separator: "/")
        guard let first = parts.first, first != "Library" else { return false }
        for (index, part) in parts.enumerated() {
            if part.hasPrefix(".") || part.hasSuffix(".app") { return false }
            if Self.dependencyFolders[String(part)] != nil { return false }
            if part == "pkg", index + 1 < parts.count, parts[index + 1] == "mod" { return false }
        }
        return true
    }

    /// The newest modification time in `project`, not counting dependency folders.
    private func newestChange(in project: Int, of tree: FileTree, skipping folders: [String: Set<String>]) -> Int64 {
        var newest = tree.modTimes[project]
        var stack = Array(tree.children(of: project).map(Int.init))
        while let node = stack.popLast() {
            if tree.kinds[node] == .directory {
                if folders[tree.names[node]] != nil { continue }
                stack.append(contentsOf: tree.children(of: node).map(Int.init))
            }
            newest = max(newest, tree.modTimes[node])
        }
        return newest
    }

    // MARK: Leftover app data

    private static let appDataLocations: [(path: String, label: String)] = [
        ("Library/Application Support", "应用数据"),
        ("Library/Caches", "缓存"),
        ("Library/Containers", "沙盒容器"),
        ("Library/Group Containers", "共享容器"),
        ("Library/Saved Application State", "窗口状态"),
        ("Library/HTTPStorages", "网络数据"),
        ("Library/WebKit", "网页数据"),
        ("Library/Logs", "日志"),
    ]

    private func leftoverAppData(in tree: FileTree, claimed: Set<Int>) -> CleanupSuggestion? {
        var items: [CleanupItem] = []
        for location in Self.appDataLocations {
            for folder in nodes(matching: "~/" + location.path, in: tree) {
                for child in tree.children(of: folder).map(Int.init) {
                    guard let id = Self.bundleID(fromFolderName: tree.names[child]),
                          !id.lowercased().hasPrefix("com.apple."),
                          !isClaimed(child, claimed, in: tree),
                          tree.totalSizes[child] >= minimumLeftoverItemSize,
                          !isAppInstalled(id)
                    else { continue }
                    items.append(CleanupItem(node: child, size: tree.totalSizes[child],
                                             label: "\(id) · \(location.label)", lastModified: nil))
                }
            }
        }
        let suggestion = CleanupSuggestion(
            id: "heuristic.leftover-apps",
            title: "已卸载应用的残留数据",
            category: .leftovers, safety: .review, regenerable: false,
            explanation: "资源库里的这些数据属于在“应用程序”文件夹中已经找不到的应用。",
            consequence: "如果应用其实装在别处或以后还会重装，它的设置和数据将丢失。",
            action: .trash, command: nil, apps: [],
            items: items.sorted { $0.size > $1.size })
        return suggestion.totalSize >= minimumSuggestionSize ? suggestion : nil
    }

    /// "com.example.App" from folder names such as "com.example.App",
    /// "com.example.App.savedState", "group.com.example.App" or "ABCDE12345.com.example.App".
    static func bundleID(fromFolderName name: String) -> String? {
        var id = Substring(name)
        for suffix in [".savedState", ".binarycookies"] where id.hasSuffix(suffix) {
            id = id.dropLast(suffix.count)
        }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        if let first = parts.first, first.count == 10,
           first.allSatisfy({ $0.isUppercase || $0.isNumber }), first.contains(where: \.isLetter) {
            id = id.dropFirst(11)  // team identifier prefix
        }
        if id.hasPrefix("group.") { id = id.dropFirst(6) }

        let components = id.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              components[0].first?.isLetter == true,
              id.allSatisfy(\.isASCII)
        else { return nil }
        return String(id)
    }

    // MARK: Paths

    /// Paths from a whole-disk scan start at /System/Volumes/Data; rules speak of /Users/….
    private func logicalPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }

    private func isUnderHome(_ node: Int, in tree: FileTree) -> Bool {
        logicalPath(tree.path(of: node)).hasPrefix(homePath + "/")
    }

    private func displayPath(of node: Int, in tree: FileTree) -> String {
        let path = logicalPath(tree.path(of: node))
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// Whether `node` or a folder containing it already belongs to an earlier suggestion.
    private func isClaimed(_ node: Int, _ claimed: Set<Int>, in tree: FileTree) -> Bool {
        guard !claimed.isEmpty else { return false }
        var i = node
        while i > 0 {
            if claimed.contains(i) { return true }
            i = Int(tree.parents[i])
        }
        return false
    }
}
