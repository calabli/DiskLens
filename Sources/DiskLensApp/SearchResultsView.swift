import DiskLensCore
import SwiftUI

/// Files and folders anywhere in the scan whose name matches the search field.
/// Selecting one shows where it is in the treemap; opening one leaves the search.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Int?

    var body: some View {
        let matches = model.searchResult?.matches ?? []
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            Divider()

            if matches.isEmpty && !model.isSearching && model.searchResult != nil {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxHeight: .infinity)
            } else {
                Table(matches, selection: $selection) {
                    TableColumn("名称") { match in
                        HStack(spacing: 6) {
                            Image(systemName: match.category.symbol)
                                .foregroundStyle(match.category.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(match.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(match.location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .help(match.location + "/" + match.name)
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("大小") { match in
                        Text(ByteFormat.string(match.size))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 64, ideal: 76)

                    TableColumn("修改时间") { match in
                        Text(match.modified, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 92)
                }
                .contextMenu(forSelectionType: Int.self) { nodes in
                    if let node = nodes.first {
                        Button("在概览中显示") { model.showSearchMatch(node) }
                        Divider()
                        NodeMenu(node: node)
                    }
                } primaryAction: { nodes in
                    if let node = nodes.first { model.showSearchMatch(node) }
                }
                .onChange(of: selection) {
                    if let selection { model.reveal(node: selection) }
                }
                .onChange(of: model.searchResult?.matches.map(\.node)) { selection = nil }
                .onDeleteCommand {
                    if let selection { model.addToBasket(selection) }
                }
                .onKeyPress(.space) {
                    model.togglePreview()
                    return .handled
                }
                .onKeyPress(.return) {
                    if let selection { model.showSearchMatch(selection) }
                    return .handled
                }
            }
        }
    }

    private var summary: String {
        guard let result = model.searchResult else { return "正在搜索…" }
        if result.total == 0 { return model.isSearching ? "正在搜索…" : "没有找到" }
        if result.total > result.matches.count {
            return "找到 \(result.total.formatted()) 项，列出最大的 \(result.matches.count) 项"
        }
        return "找到 \(result.total.formatted()) 项"
    }
}
