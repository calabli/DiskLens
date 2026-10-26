import DiskLensCore
import SwiftUI

struct TreemapPane: View {
    enum Style: String {
        case treemap, sunburst
    }

    @AppStorage("map.style") private var style = Style.treemap

    var body: some View {
        VStack(spacing: 0) {
            switch style {
            case .treemap: TreemapView()
            case .sunburst: SunburstView()
            }
            Divider()
            HStack(spacing: 0) {
                Legend()
                Picker("图表", selection: $style) {
                    Image(systemName: "square.grid.2x2").help("方块图").tag(Style.treemap)
                    Image(systemName: "circle.circle").help("环形图").tag(Style.sunburst)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.trailing, 8)
            }
        }
    }
}

/// Squarified treemap of the folder being viewed. The blocks are drawn once per
/// layout; hover, selection and basket marks are drawn on a light layer above.
///
/// Moving between folders is one camera move across two layers, the way
/// Photos and Finder zoom: the map you leave and the map you arrive at stay
/// locked together, scaled uniformly so text never stretches.
struct TreemapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [TreemapItem] = []
    @State private var layoutID = 0
    @State private var layoutSize: CGSize = .zero
    @State private var hovered: Int?
    @State private var hoverLocation: CGPoint?
    @State private var tooltipShown = false
    @State private var pendingZoom: PendingZoom?
    @State private var transition: Transition?
    @State private var transitionID = 0

    #if DEBUG
    /// DISKLENS_ANIMATION_SCALE=10 slows transitions down to inspect them frame by frame.
    nonisolated static let animationScale = ProcessInfo.processInfo.environment["DISKLENS_ANIMATION_SCALE"].flatMap(Double.init) ?? 1
    #else
    nonisolated static let animationScale = 1.0
    #endif

    private enum PendingZoom {
        /// Drilled into a folder that was drawn at this rect.
        case into(CGRect)
        /// Went up from this folder, which the new layout draws somewhere inside.
        case outOf(Int)
    }

    /// The outgoing map, kept on screen while the incoming one takes over.
    enum TransitionKind: Sendable {
        case zoomIn(Camera)
        case zoomOut(Camera)
        case fade
    }

    private struct Transition {
        let items: [TreemapItem]
        let layoutID: Int
        let kind: TransitionKind

        var duration: Double {
            if case .fade = kind { return 0.22 * TreemapView.animationScale }
            return 0.48 * TreemapView.animationScale
        }
    }

    /// A zoom from the whole view into `frame` (a rect with the view's aspect
    /// ratio), around the one point that stays put, so both layers move as one.
    struct Camera: Sendable {
        let frame: CGRect
        let scale: CGFloat
        let fixedPoint: CGPoint

        /// The largest rect with the view's aspect ratio centered inside `rect`,
        /// so the zoom grows out of the block itself.
        init?(zoomingInto rect: CGRect, viewSize size: CGSize) {
            guard rect.width > 1, rect.height > 1, size.width > 1, size.height > 1 else { return nil }
            let aspect = size.width / size.height
            var frame = rect
            if rect.width / rect.height > aspect {
                frame.size.width = rect.height * aspect
                frame.origin.x = rect.midX - frame.width / 2
            } else {
                frame.size.height = rect.width / aspect
                frame.origin.y = rect.midY - frame.height / 2
            }
            let scale = size.width / frame.width
            guard scale > 1.01 else { return nil }
            self.frame = frame
            self.scale = scale
            fixedPoint = CGPoint(x: frame.minX / (1 - 1 / scale), y: frame.minY / (1 - 1 / scale))
        }

        /// Exponential scale reads as constant speed, like Maps and Photos.
        private func zoom(_ progress: CGFloat) -> CGFloat { pow(scale, progress) }

        /// The outer map at `progress` (0 = as it was, 1 = zoomed so `frame` fills the view).
        func outer(_ progress: CGFloat) -> CGAffineTransform {
            let k = zoom(progress)
            return CGAffineTransform(a: k, b: 0, c: 0, d: k,
                                     tx: fixedPoint.x * (1 - k), ty: fixedPoint.y * (1 - k))
        }

        /// The inner map drawn into `frame` of the outer one, then zoomed with it.
        func inner(_ progress: CGFloat) -> CGAffineTransform {
            let k = zoom(progress)
            return CGAffineTransform(a: k / scale, b: 0, c: 0, d: k / scale,
                                     tx: fixedPoint.x + (frame.minX - fixedPoint.x) * k,
                                     ty: fixedPoint.y + (frame.minY - fixedPoint.y) * k)
        }
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
                    layers(tree: tree)
                    SelectionRing(rect: selectionRect)
                        .opacity(transition == nil ? 1 : 0)
                        .animation(.smooth(duration: 0.18), value: transition == nil)
                    if tooltipShown, let hovered, hovered < items.count, transition == nil {
                        Group {
                            if items[hovered].isOther {
                                OtherTooltip(count: items[hovered].otherCount, size: items[hovered].otherSize)
                            } else {
                                NodeTooltip(node: Int(items[hovered].node), category: items[hovered].category, tree: tree)
                            }
                        }
                            .fixedSize()
                            .position(tooltipPosition(in: geo.size))
                            .allowsHitTesting(false)
                            .transition(.opacity)
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
            .task(id: hovered == nil) {
                // Like macOS help tags: a short wait before the first one, then
                // they follow the pointer without delay until it leaves the map.
                guard hovered != nil else {
                    tooltipShown = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) { tooltipShown = true }
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

    /// Both maps, driven by one progress value from 0 to 1 per transition.
    private func layers(tree: FileTree) -> some View {
        let current = MapLayer(items: items, tree: tree, layoutID: layoutID,
                               marks: transition == nil ? Marks(basket: Set(model.basket), hovered: hovered) : nil)
        let outgoing = transition.map { MapLayer(items: $0.items, tree: tree, layoutID: $0.layoutID, marks: nil) }
        let kind = transition?.kind
        let duration = transition?.duration ?? 0.48
        return Color.clear
            .keyframeAnimator(initialValue: CGFloat(0), trigger: transitionID) { _, t in
                TransitionStack(progress: t, kind: kind, current: current, outgoing: outgoing)
            } keyframes: { _ in
                // Critically damped, like the system's own zooms: quick start, no bounce.
                SpringKeyframe(CGFloat(1), duration: duration, spring: .smooth(duration: duration))
            }
    }

    private var hoveredNode: Int? {
        guard let hovered, hovered < items.count, !items[hovered].isOther else { return nil }
        return Int(items[hovered].node)
    }

    private var selectionRect: CGRect? {
        guard let selection = model.selection else { return nil }
        return items.first(where: { Int($0.node) == selection && $0.depth == 1 })?.rect
    }

    private func relayout(size: CGSize) async {
        guard let tree = model.tree, size.width > 1, size.height > 1 else { return }
        let navigating = pendingZoom != nil
        if size != layoutSize && !navigating {
            // Coalesce bursts of size changes while the window or split view is being dragged.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
        }
        let root = model.current
        let bounds = CGRect(origin: .zero, size: size)
        let result = await Task.detached(priority: .userInitiated) {
            TreemapLayout.layout(tree, root: root, in: bounds)
        }.value
        guard !Task.isCancelled else { return }

        let kind = transitionKind(into: result, size: size)
        let resized = size != layoutSize
        let outgoing = items
        let outgoingID = layoutID
        pendingZoom = nil
        items = result
        layoutID += 1
        layoutSize = size
        // Keep the tooltip on whatever is under the cursor now (the map refreshes during a scan).
        hovered = hoverLocation.flatMap(hitTest)

        guard let kind, !outgoing.isEmpty, !resized || navigating else {
            transition = nil
            return
        }
        let next = Transition(items: outgoing, layoutID: outgoingID, kind: kind)
        transition = next
        transitionID += 1
        let id = transitionID
        try? await Task.sleep(for: .seconds(next.duration))
        if transitionID == id { transition = nil }
    }

    private func transitionKind(into newItems: [TreemapItem], size: CGSize) -> TransitionKind? {
        switch pendingZoom {
        case let .into(rect):
            if reduceMotion { return .fade }
            return Camera(zoomingInto: rect, viewSize: size).map { .zoomIn($0) } ?? .fade
        case let .outOf(node):
            if reduceMotion { return .fade }
            let rect = newItems.first(where: { Int($0.node) == node })?.rect
            return rect.flatMap { Camera(zoomingInto: $0, viewSize: size) }.map { .zoomOut($0) } ?? .fade
        case nil:
            // A refresh during a scan: blend into the grown map instead of jumping.
            return model.isScanning && transition == nil ? .fade : nil
        }
    }

    private func prepareZoom(from old: Int, to new: Int) {
        guard let tree = model.tree else {
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
                if item.isOther {
                    // Many small items as one block, marked so it does not read as a single file.
                    ctx.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.primary.opacity(0.1)))
                    ctx.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(.primary.opacity(0.22)),
                               style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
                    if rect.width >= 56 && rect.height >= 18 {
                        let lines = CGRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: rect.height - 4)
                        drawLabel(&ctx, name: "其他 \(item.otherCount) 项", size: rect.height >= 32 ? item.otherSize : nil,
                                  in: lines, color: .secondary, weight: .medium)
                    }
                    continue
                }
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

/// Pointer and basket marks drawn over the current map.
private struct Marks: Equatable, Sendable {
    var basket: Set<Int>
    var hovered: Int?
}

/// One map's blocks, plus its marks when it is the map being browsed.
private struct MapLayer: View, Sendable {
    let items: [TreemapItem]
    let tree: FileTree
    let layoutID: Int
    let marks: Marks?

    var body: some View {
        ZStack(alignment: .topLeading) {
            TreemapBlocks(items: items, tree: tree, layoutID: layoutID)
                .equatable()
            if let marks {
                Canvas { ctx, _ in
                    for item in items where !item.isOther && marks.basket.contains(Int(item.node)) {
                        ctx.fill(Path(item.rect), with: .color(.black.opacity(0.45)))
                        if item.rect.width > 28 && item.rect.height > 28 {
                            ctx.draw(Image(systemName: "tray.full"), at: CGPoint(x: item.rect.midX, y: item.rect.midY))
                        }
                    }
                    if let hovered = marks.hovered, hovered < items.count {
                        ctx.stroke(Path(items[hovered].rect.insetBy(dx: 0.75, dy: 0.75)),
                                   with: .color(.primary.opacity(0.9)), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        // Opaque, so the map on top fully covers the one underneath once it has faded in;
        // the blocks themselves are translucent and would otherwise show both at once.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Places the outgoing and current maps for one frame of a transition.
private struct TransitionStack: View {
    let progress: CGFloat
    let kind: TreemapView.TransitionKind?
    let current: MapLayer
    let outgoing: MapLayer?

    var body: some View {
        let t = progress
        ZStack(alignment: .topLeading) {
            switch kind {
            case let .zoomIn(camera)?:
                outgoing.transformEffect(camera.outer(t))
                current
                    .transformEffect(camera.inner(t))
                    .opacity(Double(min(1, t / 0.35)))
            case let .zoomOut(camera)?:
                current.transformEffect(camera.outer(1 - t))
                outgoing
                    .transformEffect(camera.inner(1 - t))
                    .opacity(Double(min(1, (1 - t) / 0.35)))
            case .fade?:
                outgoing
                current.opacity(Double(t))
            case nil:
                current
            }
        }
    }
}

/// The accent outline around the selected block. It glides to a new block
/// instead of jumping, like a selection moving in Finder's icon view.
private struct SelectionRing: View {
    let rect: CGRect?

    var body: some View {
        let frame = rect ?? .zero
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .opacity(rect == nil ? 0 : 1)
            .animation(.smooth(duration: 0.22), value: rect)
            .allowsHitTesting(false)
    }
}

/// What the "other" block stands for.
private struct OtherTooltip: View {
    let count: Int
    let size: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("其他 \(count) 项").fontWeight(.semibold)
            Text("\(ByteFormat.string(size)) · 每一项都太小，画不出单独的方块")
                .foregroundStyle(.secondary)
            Text("在左侧列表里可以看到每一项")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: 260, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
    }
}

/// Name, size and place of the item under the pointer, in the treemap and the sunburst.
struct NodeTooltip: View {
    let node: Int
    let category: FileCategory
    let tree: FileTree

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .foregroundStyle(category.color)
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
        if tree.kinds[node] == .directory && !category.isOpaqueBundle {
            parts.append("\(tree.fileCounts[node].formatted()) 个文件")
        } else {
            parts.append(category.label)
        }
        return parts.joined(separator: " · ")
    }

    private func relativePath(_ node: Int) -> String {
        let full = tree.path(of: node)
        return full.abbreviatingHome
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
