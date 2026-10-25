import DiskLensCore
import SwiftUI

/// Items waiting to be moved to the Trash together, after one confirmation.
struct BasketBar: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Label("收集筐", systemImage: model.basket.isEmpty ? "tray" : "tray.full")
                .font(.headline)
            if model.basket.isEmpty {
                Text("把要删除的项目拖到这里，或右键选择“加入收集筐”（也可以按 ⌫）")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.basket, id: \.self) { node in
                            BasketChip(node: node)
                        }
                    }
                }
                Text("共 \(ByteFormat.string(model.basketTotal))")
                    .monospacedDigit()
                    .fontWeight(.semibold)
                Button("清空") { model.clearBasket() }
                Button("移到废纸篓…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isScanning)
                    .help(model.isScanning ? "扫描完成后才能移到废纸篓" : "")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .background(.bar)
        .dropDestination(for: String.self) { payloads, _ in
            let nodes = payloads.compactMap(NodeDrag.node(from:))
            nodes.forEach(model.addToBasket)
            return !nodes.isEmpty
        } isTargeted: { isTargeted = $0 }
        .confirmationDialog("把 \(model.basket.count) 项（\(ByteFormat.string(model.basketTotal))）移到废纸篓？",
                            isPresented: $confirming) {
            Button("移到废纸篓", role: .destructive) { model.trashBasket() }
        } message: {
            Text("之后可以在废纸篓中恢复。清倒废纸篓后才会真正释放空间。")
        }
    }
}

private struct BasketChip: View {
    @Environment(AppModel.self) private var model
    let node: Int

    var body: some View {
        if let tree = model.tree {
            let category = FileCategory.of(name: tree.names[node], kind: tree.kinds[node])
            HStack(spacing: 4) {
                Image(systemName: category.symbol)
                    .foregroundStyle(category.color)
                Text(tree.names[node])
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                Text(ByteFormat.string(tree.totalSizes[node]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    model.removeFromBasket(node)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("从收集筐移除")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help(tree.path(of: node))
            .contextMenu {
                Button("在 Finder 中显示") { model.revealInFinder(node) }
                Button("从收集筐移除") { model.removeFromBasket(node) }
            }
        }
    }
}
