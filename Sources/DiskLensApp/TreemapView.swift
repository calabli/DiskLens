import DiskLensCore
import SwiftUI

struct TreemapPane: View {
    var body: some View {
        VStack(spacing: 0) {
            TreemapView()
            Divider()
            Legend()
        }
    }
}

/// Squarified treemap of the folder being viewed. The blocks are drawn once per
/// layout; hover, selection and basket marks are drawn on a light layer above.
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [TreemapItem] = []
    @State private var layoutID = 0
    @State private var hovered: Int?
    @State private var hoverLocation: CGPoint?
    @State private var zoom = Zoom.identity
    @State private var pendingZoom: PendingZoom?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Maps the new layout onto where it sat in the old one, animated back to identity.
    private struct Zoom: Equatable {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var x: CGFloat = 0
        var y: CGFloat = 0
        var opacity: Double = 1
        static let identity = Zoom()
    }

    private enum PendingZoom {
        /// Drilled into a folder that was drawn at this rect.
        case into(CGRect)
        /// Went up from this folder, which the new layout draws somewhere inside.
        case outOf(Int)
    }

    private struct LayoutKey: Equatable {
        var node: Int
        var version: Int
        var size: CGSize
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let tree = model.tree {
                    ZStack(alignment: .topLeading) {
                        TreemapBlocks(items: items, tree: tree, layoutID: layoutID)
                            .equatable()
                        highlights(tree: tree)
                    }
                    .scaleEffect(x: zoom.scaleX, y: zoom.scaleY, anchor: .topLeading)
                    .offset(x: zoom.x, y: zoom.y)
                    .opacity(zoom.opacity)
                    if let hovered, hovered < items.count {
                        Tooltip(item: items[hovered], tree: tree)
                            .fixedSize()
                            .position(tooltipPosition(in: geo.size))
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoverLocation = location
                    let hit = hitTest(location)
                    if hit != hovered { hovered = hit }
                case .ended:
                    hoverLocation = nil
                    hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { openBlock(at: $0.location) }
                    .exclusively(before: SpatialTapGesture().onEnded { selectBlock(at: $0.location) })
            )
            .onDrag {
                guard let location = hoverLocation, let node = topLevelNode(at: location) else { return NSItemProvider() }
                return NSItemProvider(object: NodeDrag.payload(node) as NSString)
            }
            .contextMenu {
                if let node = hoveredNode {
                    NodeMenu(node: node)
                }
            }
            .onChange(of: model.current) { old, new in
                prepareZoom(from: old, to: new)
            }
            .task(id: LayoutKey(node: model.current, version: model.treeVersion, size: geo.size)) {
                await relayout(size: geo.size)
            }
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("方块图，与左侧列表显示相同的内容")
    }

    private var hoveredNode: Int? {
        guard let hovered, hovered < items.count else { return nil }
        return Int(items[hovered].node)
    }

    private func highlights(tree: FileTree) -> some View {
        Canvas { ctx, _ in
            for item in items where model.basket.contains(Int(item.node)) {
                ctx.fill(Path(item.rect), with: .color(.black.opacity(0.45)))
                if item.rect.width > 28 && item.rect.height > 28 {
                    ctx.draw(Image(systemName: "tray.full"), at: CGPoint(x: item.rect.midX, y: item.rect.midY))
                }
            }
            if let selection = model.selection,
               let item = items.first(where: { Int($0.node) == selection && $0.depth == 1 }) {
                ctx.stroke(Path(item.rect.insetBy(dx: 1.25, dy: 1.25)), with: .color(.accentColor), lineWidth: 2.5)
            }
            if let hovered, hovered < items.count {
                ctx.stroke(Path(items[hovered].rect.insetBy(dx: 0.75, dy: 0.75)),
                           with: .color(.primary.opacity(0.9)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func relayout(size: CGSize) async {
        guard let tree = model.tree, size.width > 1, size.height > 1 else { return }
        // Coalesce bursts of size changes while the window or split view is being dragged.
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        let root = model.current
        let bounds = CGRect(origin: .zero, size: size)
        let result = await Task.detached(priority: .userInitiated) {
            TreemapLayout.layout(tree, root: root, in: bounds)
        }.value
        guard !Task.isCancelled else { return }
        let start = pendingZoom.flatMap { zoomStart(for: $0, in: result, size: size) }
        pendingZoom = nil
        items = result
        layoutID += 1
        // Keep the tooltip on whatever is under the cursor now (the map refreshes during a scan).
        hovered = hoverLocation.flatMap(hitTest)

        if let start {
            zoom = start
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(.easeOut(duration: 0.28)) { zoom = .identity }
        } else {
            zoom = .identity
        }
    }

    private func prepareZoom(from old: Int, to new: Int) {
        guard !reduceMotion, let tree = model.tree else {
            pendingZoom = nil
            return
        }
        if tree.isAncestor(old, of: new), let item = items.first(where: { Int($0.node) == new }) {
            pendingZoom = .into(item.rect)
        } else if tree.isAncestor(new, of: old) {
            pendingZoom = .outOf(old)
        } else {
            pendingZoom = nil
        }
    }

    private func zoomStart(for pending: PendingZoom, in newItems: [TreemapItem], size: CGSize) -> Zoom? {
        switch pending {
        case let .into(rect):
            // The new map starts squeezed into the block that was double-clicked.
            return Zoom(scaleX: rect.width / size.width, scaleY: rect.height / size.height,
                        x: rect.minX, y: rect.minY, opacity: 0.4)
        case let .outOf(node):
            // The new map starts blown up so the folder we left fills the view.
            guard let rect = newItems.first(where: { Int($0.node) == node })?.rect,
                  rect.width > 0, rect.height > 0 else { return nil }
            let sx = size.width / rect.width
            let sy = size.height / rect.height
            return Zoom(scaleX: sx, scaleY: sy, x: -rect.minX * sx, y: -rect.minY * sy, opacity: 0.4)
        }
    }

    /// Index of the deepest block under `point`.
    private func hitTest(_ point: CGPoint) -> Int? {
        items.indices.last { items[$0].rect.contains(point) }
    }

    private func topLevelNode(at point: CGPoint) -> Int? {
        guard let index = hitTest(point) else { return nil }
        return model.childOfCurrent(containing: Int(items[index].node))
    }

    private func selectBlock(at point: CGPoint) {
        model.selection = topLevelNode(at: point)
    }

    private func openBlock(at point: CGPoint) {
        guard let node = topLevelNode(at: point) else { return }
        model.selection = node
        model.open(node)
    }

    private func tooltipPosition(in size: CGSize) -> CGPoint {
        // Center of a ~260×70 tooltip, kept inside the view and off the cursor.
        let width: CGFloat = 260, height: CGFloat = 70
        let hoverLocation = hoverLocation ?? .zero
        var x = hoverLocation.x + 16 + width / 2
        var y = hoverLocation.y + 18 + height / 2
        if x + width / 2 > size.width { x = hoverLocation.x - 16 - width / 2 }
        if y + height / 2 > size.height { y = hoverLocation.y - 18 - height / 2 }
        return CGPoint(x: max(x, width / 2), y: max(y, height / 2))
    }
}

/// The blocks themselves. Equatable on `layoutID` so hovering does not redraw them.
private struct TreemapBlocks: View, @MainActor Equatable {
    let items: [TreemapItem]
    let tree: FileTree
    let layoutID: Int

    static func == (a: Self, b: Self) -> Bool { a.layoutID == b.layoutID }

    var body: some View {
        Canvas { ctx, _ in
            for item in items {
                let rect = item.rect
                if item.isLeaf && item.category == .folder {
                    // A folder too small to open up: an empty box, so it does not read as a file type.
                    ctx.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.primary.opacity(0.08)))
                    ctx.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(.primary.opacity(0.2)), lineWidth: 0.5)
                } else if item.isLeaf {
                    // "Other" is the most common category, so it stays quiet and lets the typed ones stand out.
                    let opacity = item.category == .other ? 0.4 : 0.8
                    ctx.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(item.category.color.opacity(opacity)))
                } else {
                    ctx.fill(Path(rect), with: .color(.primary.opacity(0.05)))
                    ctx.stroke(Path(rect.insetBy(dx: 0.25, dy: 0.25)), with: .color(.primary.opacity(0.15)), lineWidth: 0.5)
                }
                if item.hasHeader {
                    drawLabel(&ctx, name: tree.names[Int(item.node)], size: tree.totalSizes[Int(item.node)],
                              in: CGRect(x: rect.minX + 4, y: rect.minY + 1, width: rect.width - 8, height: 15),
                              color: .secondary, weight: .semibold)
                } else if item.isLeaf && rect.width >= 56 && rect.height >= 18 {
                    let lines = CGRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: rect.height - 4)
                    drawLabel(&ctx, name: tree.names[Int(item.node)],
                              size: rect.height >= 32 ? tree.totalSizes[Int(item.node)] : nil,
                              in: lines, color: .black.opacity(0.78), weight: .medium)
                }
            }
        }
    }

    private func drawLabel(_ ctx: inout GraphicsContext, name: String, size: Int64?, in rect: CGRect,
                           color: Color, weight: Font.Weight) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            let title = Text(name).font(.system(size: 10.5, weight: weight)).foregroundColor(color)
            layer.draw(title, at: rect.origin, anchor: .topLeading)
            if let size, rect.height >= 28 {
                let detail = Text(ByteFormat.string(size)).font(.system(size: 10)).foregroundColor(color.opacity(0.8))
                layer.draw(detail, at: CGPoint(x: rect.minX, y: rect.minY + 13), anchor: .topLeading)
            }
        }
    }
}

private struct Tooltip: View {
    let item: TreemapItem
    let tree: FileTree

    var body: some View {
        let node = Int(item.node)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.category.symbol)
                    .foregroundStyle(item.category.color)
                Text(tree.names[node])
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(detail(node))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(relativePath(node))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.callout)
        .frame(maxWidth: 260, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
    }

    private func detail(_ node: Int) -> String {
        var parts = [ByteFormat.string(tree.totalSizes[node])]
        if tree.kinds[node] == .directory && !item.category.isOpaqueBundle {
            parts.append("\(tree.fileCounts[node].formatted()) 个文件")
        } else {
            parts.append(item.category.label)
        }
        return parts.joined(separator: " · ")
    }

    private func relativePath(_ node: Int) -> String {
        let full = tree.path(of: node)
        return (full as NSString).abbreviatingWithTildeInPath
    }
}

private struct Legend: View {
    private let categories: [FileCategory] = [.video, .image, .audio, .document, .code, .archive,
                                              .diskImage, .application, .other]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.self) { category in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color.opacity(category == .other ? 0.4 : 0.8))
                            .frame(width: 10, height: 10)
                        Text(category.label)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
