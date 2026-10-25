import DiskLensCore
import SwiftUI

/// One row of the large-files table, with the last-used date resolved.
private struct LargeFileRow: Identifiable {
    let file: LargeFile
    /// Last opened according to Spotlight, else last modified.
    let lastUsed: Date
    let lastUsedIsKnown: Bool

    var id: Int { file.node }
    var name: String { file.name }
    var size: Int64 { file.size }
    var location: String { file.location }
    var modified: Date { file.modified }
}

/// The biggest files in the scan, filterable by size, type, idle time and name.
struct LargeFilesView: View {
    @Environment(AppModel.self) private var model
    @State private var minimumSize: Int64 = 100_000_000
    @State private var category: FileCategory?
    @State private var unusedFor: UnusedPeriod = .any
    @State private var search = ""
    @State private var selection = Set<Int>()
    @State private var sortOrder = [KeyPathComparator(\LargeFileRow.size, order: .reverse)]

    private enum UnusedPeriod: Double, CaseIterable, Identifiable {
        case any = 0
        case threeMonths = 91
        case sixMonths = 182
        case oneYear = 365
        case twoYears = 730

        var id: Double { rawValue }

        var title: String {
            switch self {
            case .any: "不限"
            case .threeMonths: "3 个月以上"
            case .sixMonths: "半年以上"
            case .oneYear: "1 年以上"
            case .twoYears: "2 年以上"
            }
        }
    }

    private var rows: [LargeFileRow] {
        let cutoff = Date().addingTimeInterval(-unusedFor.rawValue * 86_400)
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.largeFiles.compactMap { file -> LargeFileRow? in
            guard file.size >= minimumSize,
                  category == nil || file.category == category,
                  query.isEmpty || file.name.localizedCaseInsensitiveContains(query)
                    || file.location.localizedCaseInsensitiveContains(query)
            else { return nil }
            let known = model.lastUsed[file.node]
            let lastUsed = known ?? file.modified
            guard unusedFor == .any || lastUsed < cutoff else { return nil }
            return LargeFileRow(file: file, lastUsed: lastUsed, lastUsedIsKnown: known != nil)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        if model.isScanning {
            ContentUnavailableView("扫描完成后列出大文件", systemImage: "hourglass")
        } else {
            let rows = rows
            VStack(spacing: 0) {
                filterBar(rows: rows)
                Divider()
                if rows.isEmpty {
                    ContentUnavailableView("没有符合条件的文件", systemImage: "doc.text.magnifyingglass",
                                           description: Text("试试放宽大小、类型或使用时间的条件。"))
                } else {
                    table(rows: rows)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "搜索文件名或位置")
        }
    }

    private func filterBar(rows: [LargeFileRow]) -> some View {
        HStack(spacing: 14) {
            Picker("大小", selection: $minimumSize) {
                Text("≥ 100 MB").tag(Int64(100_000_000))
                Text("≥ 500 MB").tag(Int64(500_000_000))
                Text("≥ 1 GB").tag(Int64(1_000_000_000))
                Text("≥ 5 GB").tag(Int64(5_000_000_000))
            }
            .fixedSize()
            Picker("类型", selection: $category) {
                Text("全部").tag(FileCategory?.none)
                Divider()
                ForEach(availableCategories, id: \.self) { category in
                    Label(category.label, systemImage: category.symbol).tag(Optional(category))
                }
            }
            .fixedSize()
            Picker("未使用", selection: $unusedFor) {
                ForEach(UnusedPeriod.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help("按上次打开的时间（来自 Spotlight），没有记录时按修改时间")
            Spacer()
            Text("\(rows.count) 个 · \(ByteFormat.string(rows.reduce(0) { $0 + $1.size }))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                selection.forEach(model.addToBasket)
            } label: {
                Label("加入收集筐", systemImage: "tray.and.arrow.down")
            }
            .disabled(selection.isEmpty)
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var availableCategories: [FileCategory] {
        let present = Set(model.largeFiles.map(\.category))
        return FileCategory.allCases.filter { $0 != .folder && present.contains($0) }
    }

    private func table(rows: [LargeFileRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.file.category.symbol)
                        .foregroundStyle(row.file.category.color)
                        .frame(width: 16)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.file.isAppData {
                        Text("应用数据")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("位于资源库中，通常属于某个应用，删除前请确认")
                    }
                    if model.isInBasket(row.id) {
                        Image(systemName: "tray.full")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(model.isInBasket(row.id) ? 0.45 : 1)
            }
            .width(min: 180, ideal: 280)

            TableColumn("大小", value: \.size) { row in
                Text(ByteFormat.string(row.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)

            TableColumn("位置", value: \.location) { row in
                Text(row.location)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(row.location)
            }
            .width(min: 140, ideal: 260)

            TableColumn("上次使用", value: \.lastUsed) { row in
                Text(row.lastUsedIsKnown ? row.lastUsed.formatted(date: .abbreviated, time: .omitted) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(row.lastUsedIsKnown ? "上次打开的时间" : "Spotlight 没有记录，筛选时按修改时间")
            }
            .width(min: 80, ideal: 100)

            TableColumn("修改时间", value: \.modified) { row in
                Text(row.modified.formatted(date: .abbreviated, time: .omitted))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: Int.self) { nodes in
            if !nodes.isEmpty {
                Button(nodes.count > 1 ? "将 \(nodes.count) 项加入收集筐" : "加入收集筐") {
                    nodes.forEach(model.addToBasket)
                }
                Divider()
                if let node = nodes.first {
                    Button("快速查看") { model.previewURL = model.url(of: node) }
                    Button("在 Finder 中显示") { model.revealInFinder(node) }
                    Button("拷贝路径") { model.copyPath(node) }
                }
            }
        } primaryAction: { nodes in
            if let node = nodes.first { model.previewURL = model.url(of: node) }
        }
        .onDeleteCommand {
            selection.forEach(model.addToBasket)
        }
        .onKeyPress(.space) {
            if let node = selection.first {
                model.previewURL = model.previewURL == nil ? model.url(of: node) : nil
            }
            return .handled
        }
    }
}
