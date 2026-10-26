import DiskLensCore
import SwiftUI

/// The folder being viewed as rings: its contents on the innermost ring, theirs
/// on the next, each arc as wide as its share of the space. The same clicks as
/// the treemap: click to select, double-click a folder to open it, and click
/// the middle to go up a level.
struct SunburstView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var segments: [SunburstSegment] = []
    /// Names of the inner two rings, which get labels.
    @State private var names: [Int32: String] = [:]
    @State private var layoutID = 0
    @State private var layoutRoot: Int?
    /// Bumped when a different folder is shown, to sweep its rings in.
    @State private var sweepID = 0
    @State private var hovered: Hit?
    @State private var hoverLocation: CGPoint?
    @State private var tooltipShown = false

    private enum Hit: Equatable {
        case center
        case segment(Int)
    }

    private struct LayoutKey: Equatable {
        let node: Int
        let version: Int
    }

    @State private var size: CGSize = .zero

    private var rings: Rings { Rings(size: size, depth: segments.map(\.depth).max() ?? 1) }

    var body: some View {
        GeometryReader { geo in
            content
                .task(id: geo.size) { size = geo.size }
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("环形图，与左侧列表显示相同的内容")
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            if let tree = model.tree {
                arcs
                marks
                CenterLabel(node: model.current, tree: tree, canGoUp: model.canGoUp, isHovered: hovered == .center)
                    .frame(width: rings.hole * 1.6)
                    .position(rings.center)
                    .allowsHitTesting(false)
                tooltip(tree: tree)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .task(id: hovered == nil || hovered == .center) {
            guard case .segment = hovered else {
                tooltipShown = false
                return
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { tooltipShown = true }
        }
        .gesture(
            SpatialTapGesture(count: 2)
                .onEnded { open(at: $0.location) }
                .exclusively(before: SpatialTapGesture().onEnded { select(at: $0.location) })
        )
        .onDrag {
            guard let location = hoverLocation, let node = topLevelNode(at: location) else { return NSItemProvider() }
            return NSItemProvider(object: NodeDrag.payload(node) as NSString)
        }
        .contextMenu {
            if let index = hoveredIndex, !segments[index].isRemainder {
                NodeMenu(node: Int(segments[index].node))
            }
        }
        .task(id: LayoutKey(node: model.current, version: model.treeVersion)) {
            await relayout()
        }
    }

    private var arcs: some View {
        let segments = segments, rings = rings, layoutID = layoutID, names = names
        return Color.clear
            .keyframeAnimator(initialValue: CGFloat(1), trigger: sweepID) { _, sweep in
                SunburstArcs(segments: segments, names: names, rings: rings, layoutID: layoutID, sweep: sweep)
                    .equatable()
            } keyframes: { _ in
                MoveKeyframe(CGFloat(0))
                SpringKeyframe(CGFloat(1), duration: 0.55, spring: .smooth(duration: 0.55))
            }
    }

    @ViewBuilder
    private func tooltip(tree: FileTree) -> some View {
        if tooltipShown, let index = hoveredIndex, !segments[index].isRemainder {
            NodeTooltip(node: Int(segments[index].node), category: segments[index].category, tree: tree)
                .fixedSize()
                .position(tooltipPosition(in: size))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var hoveredIndex: Int? {
        if case let .segment(index) = hovered, index < segments.count { return index }
        return nil
    }

    /// Hover and selection drawn over the arcs, so moving the pointer does not redraw them.
    private var marks: some View {
        let selected = model.selection.flatMap { node in
            segments.firstIndex { $0.depth == 1 && Int($0.node) == node && !$0.isRemainder }
        }
        let hoveredIndex = hoveredIndex, segments = segments, rings = rings
        return Canvas { ctx, _ in
            if let hoveredIndex {
                ctx.fill(rings.path(for: segments[hoveredIndex]), with: .color(.white.opacity(0.28)))
            }
            if let selected {
                ctx.stroke(rings.path(for: segments[selected]), with: .color(.accentColor), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func relayout() async {
        guard let tree = model.tree else { return }
        let root = model.current
        let (result, labels) = await Task.detached(priority: .userInitiated) {
            let segments = SunburstLayout.layout(tree, root: root)
            var names: [Int32: String] = [:]
            for segment in segments where segment.depth <= 2 && !segment.isRemainder {
                names[segment.node] = tree.names[Int(segment.node)]
            }
            return (segments, names)
        }.value
        guard !Task.isCancelled else { return }
        segments = result
        names = labels
        layoutID += 1
        if root != layoutRoot {
            if layoutRoot != nil && !reduceMotion { sweepID += 1 }
            layoutRoot = root
        }
        hovered = hoverLocation.flatMap(hitTest)
    }

    private func hitTest(_ point: CGPoint) -> Hit? {
        guard let (depth, turn) = rings.locate(point) else { return nil }
        if depth == 0 { return .center }
        return segments.indices.last { i in
            segments[i].depth == depth && segments[i].start <= turn && turn < segments[i].end
        }.map(Hit.segment)
    }

    private func topLevelNode(at point: CGPoint) -> Int? {
        guard case let .segment(index) = hitTest(point), !segments[index].isRemainder else { return nil }
        return model.childOfCurrent(containing: Int(segments[index].node))
    }

    private func select(at point: CGPoint) {
        if hitTest(point) == .center {
            model.goUp()
        } else {
            model.selection = topLevelNode(at: point)
        }
    }

    private func open(at point: CGPoint) {
        guard case let .segment(index) = hitTest(point), !segments[index].isRemainder else { return }
        let segment = segments[index]
        if segment.opensUp {
            model.open(Int(segment.node))
        } else {
            model.selection = model.childOfCurrent(containing: Int(segment.node))
        }
    }

    private func tooltipPosition(in size: CGSize) -> CGPoint {
        let width: CGFloat = 260, height: CGFloat = 70
        let hoverLocation = hoverLocation ?? .zero
        var x = hoverLocation.x + 16 + width / 2
        var y = hoverLocation.y + 18 + height / 2
        if x + width / 2 > size.width { x = hoverLocation.x - 16 - width / 2 }
        if y + height / 2 > size.height { y = hoverLocation.y - 18 - height / 2 }
        return CGPoint(x: max(x, width / 2), y: max(y, height / 2))
    }
}

/// Where the rings sit in the view: a hole in the middle for the folder's name,
/// then one ring per level out to the edge.
private struct Rings: Equatable, Sendable {
    let center: CGPoint
    let hole: CGFloat
    let width: CGFloat
    let count: Int

    init(size: CGSize, depth: Int) {
        let radius = max(min(size.width, size.height) / 2 - 14, 40)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        hole = radius * 0.27
        count = max(depth, 1)
        width = (radius - hole) / CGFloat(count)
    }

    func radii(depth: Int) -> (inner: CGFloat, outer: CGFloat) {
        (hole + CGFloat(depth - 1) * width + 1, hole + CGFloat(depth) * width)
    }

    func path(for segment: SunburstSegment, upTo sweep: Double = 1) -> Path {
        let (inner, outer) = radii(depth: segment.depth)
        let end = min(segment.end, sweep)
        let from = Angle.radians(segment.start * 2 * .pi - .pi / 2)
        let to = Angle.radians(end * 2 * .pi - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// The ring under `point` (0 for the hole) and how far round the turn it is, 0..<1 from 12 o'clock.
    func locate(_ point: CGPoint) -> (depth: Int, turn: Double)? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < hole { return (0, 0) }
        let depth = Int((distance - hole) / width) + 1
        guard depth <= count else { return nil }
        var angle = atan2(Double(dx), Double(-dy))
        if angle < 0 { angle += 2 * .pi }
        return (depth, angle / (2 * .pi))
    }
}

/// The arcs themselves. Equatable on the layout and sweep so hovering does not redraw them.
private struct SunburstArcs: View, Equatable, Sendable {
    let segments: [SunburstSegment]
    let names: [Int32: String]
    let rings: Rings
    let layoutID: Int
    let sweep: CGFloat

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.layoutID == b.layoutID && a.sweep == b.sweep && a.rings == b.rings
    }

    var body: some View {
        Canvas { ctx, _ in
            let separator = Color(nsColor: .windowBackgroundColor)
            for segment in segments where segment.start < Double(sweep) {
                let path = rings.path(for: segment, upTo: Double(sweep))
                ctx.fill(path, with: .color(fill(for: segment)))
                ctx.stroke(path, with: .color(separator), lineWidth: 0.75)
            }
            guard sweep >= 1 else { return }
            for segment in segments where segment.depth <= 2 && !segment.isRemainder {
                if let name = names[segment.node] { drawLabel(&ctx, name: name, on: segment) }
            }
        }
    }

    /// The name across the middle of the arc, if the arc is long enough to hold it.
    private func drawLabel(_ ctx: inout GraphicsContext, name: String, on segment: SunburstSegment) {
        let (inner, outer) = rings.radii(depth: segment.depth)
        guard outer - inner >= 15 else { return }
        let middle = (inner + outer) / 2
        let length = CGFloat(segment.end - segment.start) * 2 * .pi * middle
        let estimated = name.unicodeScalars.reduce(CGFloat(8)) { $0 + ($1.value > 0x2E80 ? 11 : 6.2) }
        guard length >= min(estimated, 90) else { return }
        let angle = (segment.start + segment.end) * .pi - .pi / 2
        let point = CGPoint(x: rings.center.x + middle * cos(angle), y: rings.center.y + middle * sin(angle))
        // Along the arc, turned so it never reads upside down.
        var tangent = angle + .pi / 2
        if sin(angle) > 0 { tangent += .pi }
        ctx.drawLayer { layer in
            layer.clip(to: rings.path(for: segment))
            layer.translateBy(x: point.x, y: point.y)
            layer.rotate(by: .radians(tangent))
            let text = Text(name).font(.system(size: 10.5, weight: .medium)).foregroundColor(.black.opacity(0.75))
            layer.draw(text, at: .zero, anchor: .center)
        }
    }

    private func fill(for segment: SunburstSegment) -> Color {
        if segment.isRemainder { return .primary.opacity(0.07) }
        let kind = segment.tint
        if kind == .folder { return .primary.opacity(0.1) }
        // Files at full strength; folders lighter, tinted by what fills them.
        let strength = segment.category == .folder ? 0.5 : 0.8
        return kind.color.opacity(kind == .other ? strength / 2 : strength)
    }
}

private struct CenterLabel: View {
    let node: Int
    let tree: FileTree
    let canGoUp: Bool
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 2) {
            if canGoUp {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
            }
            Text(node == 0 ? tree.rootPath.abbreviatingHome : tree.names[node])
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(ByteFormat.string(tree.totalSizes[node]))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
