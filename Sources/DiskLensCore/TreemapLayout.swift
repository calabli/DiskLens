import CoreGraphics

public struct TreemapItem: Sendable {
    public var node: Int32
    public var rect: CGRect
    /// 1 for the children of the layout root, 2 for their children, and so on.
    public var depth: Int
    /// Drawn as a filled block (a file, a bundle, or a folder too small to open up).
    public var isLeaf: Bool
    /// A folder with a title strip across its top.
    public var hasHeader: Bool
    public var category: FileCategory
    /// For the block standing in for children too small to draw, how many it
    /// covers and their total size; `node` is then their parent. 0 for others.
    public var otherCount = 0
    public var otherSize: Int64 = 0

    public var isOther: Bool { otherCount > 0 }
}

public struct TreemapOptions: Sendable {
    /// Blocks smaller than this on either side are not drawn; their space stays empty.
    public var minSide: CGFloat = 3
    public var maxItems = 60_000
    public var padding: CGFloat = 1.5
    public var headerHeight: CGFloat = 16
    public var headerMinSize = CGSize(width: 72, height: 44)

    public init() {}
}

/// Squarified treemap (Bruls, Huizing, van Wijk 2000): rows of blocks whose
/// aspect ratios stay close to 1, nested folder inside folder.
public enum TreemapLayout {
    /// Lays out the children of `root` inside `bounds`, parents before their children.
    public static func layout(_ tree: FileTree, root: Int, in bounds: CGRect,
                              options: TreemapOptions = TreemapOptions()) -> [TreemapItem] {
        var items: [TreemapItem] = []
        items.reserveCapacity(4096)
        layoutChildren(of: root, in: bounds, depth: 1, tree: tree, options: options, items: &items)
        return items
    }

    private static func layoutChildren(of node: Int, in rect: CGRect, depth: Int, tree: FileTree,
                                       options: TreemapOptions, items: inout [TreemapItem]) {
        let children = tree.children(of: node)
        let total = children.reduce(Int64(0)) { $0 + tree.totalSizes[Int($1)] }
        guard total > 0, rect.width >= options.minSide, rect.height >= options.minSide else { return }

        let scale = Double(rect.width * rect.height) / Double(total)
        let minArea = Double(options.minSide * options.minSide)
        var areas: [Double] = []
        for child in children {
            let area = Double(tree.totalSizes[Int(child)]) * scale
            if area < minArea { break }  // children are sorted largest first
            areas.append(area)
        }

        // The children too small to draw share one "other" block, placed by its size among the rest.
        let small = children.dropFirst(areas.count)
        let smallSize = small.reduce(Int64(0)) { $0 + tree.totalSizes[Int($1)] }
        let otherArea = Double(smallSize) * scale
        let otherIndex = otherArea >= minArea * 4 ? (areas.firstIndex { $0 < otherArea } ?? areas.count) : nil
        if let otherIndex { areas.insert(otherArea, at: otherIndex) }

        var next = children.startIndex
        for (index, childRect) in squarify(areas, in: rect).enumerated() {
            guard items.count < options.maxItems else { return }
            if index == otherIndex {
                items.append(TreemapItem(node: Int32(node), rect: childRect, depth: depth, isLeaf: true, hasHeader: false,
                                         category: .other, otherCount: small.count, otherSize: smallSize))
                continue
            }
            place(Int(children[next]), in: childRect, depth: depth, tree: tree, options: options, items: &items)
            next += 1
        }
    }

    private static func place(_ node: Int, in rect: CGRect, depth: Int, tree: FileTree,
                              options: TreemapOptions, items: inout [TreemapItem]) {
        let category = FileCategory.of(name: tree.names[node], kind: tree.kinds[node])
        var inner = rect.insetBy(dx: options.padding, dy: options.padding)
        let hasHeader = rect.width >= options.headerMinSize.width && rect.height >= options.headerMinSize.height
        if hasHeader {
            inner.origin.y += options.headerHeight
            inner.size.height -= options.headerHeight
        }
        let opensUp = tree.kinds[node] == .directory && !category.isOpaqueBundle
            && !tree.children(of: node).isEmpty
            && inner.width >= options.minSide * 2 && inner.height >= options.minSide * 2

        items.append(TreemapItem(node: Int32(node), rect: rect, depth: depth, isLeaf: !opensUp,
                                 hasHeader: opensUp && hasHeader, category: category))
        if opensUp {
            layoutChildren(of: node, in: inner, depth: depth + 1, tree: tree, options: options, items: &items)
        }
    }

    /// Splits `rect` into blocks with the given areas (largest first). If the areas
    /// add up to less than the rect, the leftover space is at the end.
    static func squarify(_ areas: [Double], in rect: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var free = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(free.width, free.height))
            guard side > 0 else { break }

            var rowSum = areas[i]
            var rowMin = areas[i]
            var rowMax = areas[i]
            var worst = worstRatio(sum: rowSum, min: rowMin, max: rowMax, side: side)
            var j = i + 1
            while j < areas.count {
                let a = areas[j]
                let next = worstRatio(sum: rowSum + a, min: Swift.min(rowMin, a), max: Swift.max(rowMax, a), side: side)
                if next > worst { break }
                rowSum += a
                rowMin = Swift.min(rowMin, a)
                rowMax = Swift.max(rowMax, a)
                worst = next
                j += 1
            }

            let thickness = CGFloat(rowSum / side)
            if free.width >= free.height {
                // A column along the left edge.
                var y = free.minY
                for k in i..<j {
                    let h = CGFloat(areas[k]) / thickness
                    result.append(CGRect(x: free.minX, y: y, width: thickness, height: h))
                    y += h
                }
                free.origin.x += thickness
                free.size.width = max(free.width - thickness, 0)
            } else {
                // A row along the top edge.
                var x = free.minX
                for k in i..<j {
                    let w = CGFloat(areas[k]) / thickness
                    result.append(CGRect(x: x, y: free.minY, width: w, height: thickness))
                    x += w
                }
                free.origin.y += thickness
                free.size.height = max(free.height - thickness, 0)
            }
            i = j
        }
        return result
    }

    private static func worstRatio(sum: Double, min: Double, max: Double, side: Double) -> Double {
        let s2 = sum * sum
        let w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }
}
