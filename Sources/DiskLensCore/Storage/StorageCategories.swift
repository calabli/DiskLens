/// A whole-disk scan sorted into the categories of System Settings › Storage.
/// macOS does not publish how it works these out, so the folders here were matched
/// against its numbers on a real Mac and the totals come out close, not equal.
/// System Data has no folder of its own: it is whatever the other categories leave.
public struct StorageCategories: Sendable {
    public enum Category: CaseIterable, Sendable {
        case developer, documents, applications, mail, photos, iCloudDrive, otherUsers, macOS, systemData
    }

    /// The largest things inside System Data, each a folder or two a scan can measure.
    public enum SystemPart: CaseIterable, Sendable {
        case wallpapers, caches, systemAssets, temporaryFiles, swap, databases, logs, commandLineTools, other
    }

    public let sizes: [Category: Int64]
    public let systemParts: [SystemPart: Int64]

    /// Sorts `tree`, a scan of the data volume. `homePath` is the logical home
    /// folder (/Users/…), found under the tree's root.
    public init(tree: FileTree, breakdown: StorageBreakdown, homePath: String = UserHome.path) {
        func size(_ path: String) -> Int64 {
            tree.node(atPath: tree.rootPath + path).map { tree.totalSizes[$0] } ?? 0
        }
        func total(_ paths: String...) -> Int64 {
            paths.reduce(0) { $0 + size($1) }
        }
        let home = homePath
        let library = home + "/Library"

        // Apple's own folders in Application Support belong to macOS, not to an app.
        var appSupport: Int64 = 0
        if let node = tree.node(atPath: tree.rootPath + library + "/Application Support") {
            appSupport = tree.children(of: node).map(Int.init)
                .filter { !tree.names[$0].hasPrefix("com.apple.") }
                .reduce(0) { $0 + tree.totalSizes[$1] }
        }

        var sizes: [Category: Int64] = [:]
        sizes[.developer] = total(library + "/Developer", "/Library/Developer")
        sizes[.applications] = appSupport + total("/Applications", home + "/Applications", library + "/Containers",
                                                  library + "/Group Containers")
        sizes[.mail] = size(library + "/Mail")
        sizes[.photos] = size(home + "/Pictures/Photos Library.photoslibrary")
        sizes[.iCloudDrive] = size(library + "/Mobile Documents")
        sizes[.otherUsers] = max(size("/Users") - size(home), 0)
        sizes[.documents] = max(size(home) - total(library, home + "/Applications") - sizes[.photos, default: 0], 0)
        sizes[.macOS] = breakdown.volumes.filter { [.system, .preboot, .recovery, .update, .vm].contains($0.role) }
            .reduce(0) { $0 + $1.used }

        // Settings leaves out purgeable space, so its categories add up to less than "used".
        let shown = breakdown.containerUsed - breakdown.purgeable
        let systemData = max(shown - sizes.values.reduce(0, +), 0)
        sizes[.systemData] = systemData
        self.sizes = sizes

        var parts: [SystemPart: Int64] = [:]
        parts[.wallpapers] = size(library + "/Application Support/com.apple.wallpaper")
        parts[.caches] = total(library + "/Caches", "/Library/Caches")
        parts[.systemAssets] = size("/System")
        parts[.temporaryFiles] = total("/private/var/folders", "/private/tmp")
        parts[.swap] = size("/private/var/vm")
        parts[.databases] = size("/private/var/db")
        parts[.logs] = total(library + "/Logs", "/Library/Logs", "/private/var/log")
        parts[.commandLineTools] = total("/usr/local", "/opt")
        parts[.other] = max(systemData - parts.values.reduce(0, +), 0)
        systemParts = parts
    }
}
