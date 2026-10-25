import DiskLensCore
import SwiftUI

struct FolderTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(of: FolderRow.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("名称", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.category.symbol)
                        .foregroundStyle(row.category.color)
                        .frame(width: 16)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(model.isInBasket(row.id) ? 0.45 : 1)
                    if model.isInBasket(row.id) {
                        Image(systemName: "tray.full")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("已在收集筐中")
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("大小", value: \.size) { row in
                HStack(spacing: 8) {
                    SizeBar(fraction: row.relative, color: row.category.color)
                    Text(ByteFormat.string(row.size))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .width(min: 120, ideal: 150)

            TableColumn("占比", value: \.share) { row in
                Text(row.share, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 48, ideal: 56)

            TableColumn("文件数", value: \.files) { row in
                Text(row.isDirectory ? row.files.formatted() : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)

            TableColumn("修改时间", value: \.modified) { row in
                Text(row.modified, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 92)
        } rows: {
            ForEach(model.rows) { row in
                TableRow(row)
                    .draggable(NodeDrag.payload(row.id))
            }
        }
        .contextMenu(forSelectionType: Int.self) { nodes in
            if let node = nodes.first {
                NodeMenu(node: node)
            }
        } primaryAction: { nodes in
            if let node = nodes.first { model.open(node) }
        }
        .onDeleteCommand {
            if let selection = model.selection { model.addToBasket(selection) }
        }
        .onKeyPress(.space) {
            model.togglePreview()
            return .handled
        }
        .onKeyPress(.return) {
            if let selection = model.selection { model.open(selection) }
            return .handled
        }
    }
}

private struct SizeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(color.opacity(0.75))
                .frame(width: max(geo.size.width * fraction, 2))
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 6)
    }
}

/// The actions offered for a file or folder, in the list and in the treemap.
struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: Int

    var body: some View {
        if let tree = model.tree, !tree.isRemoved(node) {
            if tree.kinds[node] == .directory {
                Button("打开") { model.open(node) }
            }
            Button("在 Finder 中显示") { model.revealInFinder(node) }
            Button("快速查看") { model.previewURL = model.url(of: node) }
            Button("拷贝路径") { model.copyPath(node) }
            Divider()
            if model.basket.contains(node) {
                Button("从收集筐移除") { model.removeFromBasket(node) }
            } else if model.isInBasket(node) {
                Button("所在文件夹已在收集筐中") {}
                    .disabled(true)
            } else {
                Button("加入收集筐") { model.addToBasket(node) }
            }
        }
    }
}

extension FileCategory {
    var color: Color {
        switch self {
        case .folder: Color(nsColor: .systemBlue)
        case .application: Color(nsColor: .systemPurple)
        case .video: Color(nsColor: .systemRed)
        case .image: Color(nsColor: .systemOrange)
        case .audio: Color(nsColor: .systemPink)
        case .document: Color(nsColor: .systemIndigo)
        case .code: Color(nsColor: .systemGreen)
        case .archive: Color(nsColor: .systemBrown)
        case .diskImage: Color(nsColor: .systemYellow)
        case .other: Color(nsColor: .systemGray)
        }
    }

    var label: String {
        switch self {
        case .folder: "文件夹"
        case .application: "应用"
        case .video: "视频"
        case .image: "图片"
        case .audio: "音频"
        case .document: "文档"
        case .code: "代码与数据"
        case .archive: "压缩包"
        case .diskImage: "磁盘映像与安装包"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .application: "app.fill"
        case .video: "film"
        case .image: "photo"
        case .audio: "music.note"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox"
        case .diskImage: "opticaldiscdrive"
        case .other: "doc"
        }
    }
}
