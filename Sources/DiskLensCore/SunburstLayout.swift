/// One arc of a sunburst: a file or folder on the ring for its depth, spanning
/// a share of the turn proportional to its size.
public struct SunburstSegment: Sendable {
    public var node: Int32
    /// 1 for the children of the layout root (the innermost ring), 2 for theirs, and so on.
    public var depth: Int
    /// Where the arc starts and ends, as fractions of a full turn clockwise from 12 o'clock.
    public var start: Double
    public var end: Double
    /// The item's own kind: a file type, or `.folder`.
    public var category: FileCategory
    /// What to colour it by: for a file its own type; for a folder, the type of
    /// the largest file down its largest branch, so a folder of videos reads as video.
    public var tint: FileCategory
    /// A folder whose contents are drawn on the next ring out.
    public var opensUp: Bool
    /// Stands for all the children of `node` too small to draw, together.
    public var isRemainder: Bool
}

public struct SunburstOptions: Sendable {
    public var maxDepth = 6
    /// Arcs narrower than this share of the turn are folded into one remainder arc.
    public var minSpan = 0.003
    public var maxSegments = 20_000

    public init() {}
}

public enum SunburstLayout {
    /// Lays out the contents of `root` as rings around it, parents before their children.
    public static func layout(_ tree: FileTree, root: Int,
                              options: SunburstOptions = SunburstOptions()) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        segments.reserveCapacity(2048)
        layoutChildren(of: root, from: 0, to: 1, depth: 1, tree: tree, options: options, into: &segments)
        return segments
    }

    private static func layoutChildren(of node: Int, from start: Double, to end: Double, depth: Int,
                                       tree: FileTree, options: SunburstOptions,
                                       into segments: inout [SunburstSegment]) {
        let children = tree.children(of: node)
        let total = children.reduce(Int64(0)) { $0 + tree.totalSizes[Int($1)] }
        guard total > 0, end - start >= options.minSpan else { return }

        let scale = (end - start) / Double(total)
        var angle = start
        for child in children.map(Int.init) {
            let span = Double(tree.totalSizes[child]) * scale
            guard span >= options.minSpan, segments.count < options.maxSegments else {
                // Children are largest first: everything from here on is smaller still.
                if end - angle >= options.minSpan / 4 {
                    segments.append(SunburstSegment(node: Int32(node), depth: depth, start: angle, end: end,
                                                    category: .other, tint: .other, opensUp: false, isRemainder: true))
                }
                return
            }
            let category = FileCategory.of(name: tree.names[child], kind: tree.kinds[child])
            let opensUp = tree.kinds[child] == .directory && !category.isOpaqueBundle
                && !tree.children(of: child).isEmpty
            segments.append(SunburstSegment(node: Int32(child), depth: depth, start: angle, end: angle + span,
                                            category: category, tint: tint(of: child, category: category, in: tree),
                                            opensUp: opensUp, isRemainder: false))
            if opensUp && depth < options.maxDepth {
                layoutChildren(of: child, from: angle, to: angle + span, depth: depth + 1, tree: tree,
                               options: options, into: &segments)
            }
            angle += span
        }
    }

    /// Follows the largest child down from a folder to the first file or bundle.
    static func tint(of node: Int, category: FileCategory, in tree: FileTree) -> FileCategory {
        guard tree.kinds[node] == .directory, !category.isOpaqueBundle else { return category }
        var i = node
        for _ in 0..<64 {
            guard let largest = tree.children(of: i).first.map(Int.init) else { return .folder }
            let kind = FileCategory.of(name: tree.names[largest], kind: tree.kinds[largest])
            if tree.kinds[largest] != .directory || kind.isOpaqueBundle { return kind }
            i = largest
        }
        return .folder
    }
}
