import AppKit
import DiskLensCore
import SwiftUI

/// Every time the basket went to the Trash, with a way to put things back
/// while they are still there.
struct CleanupHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.cleanupRecords.isEmpty {
                ContentUnavailableView("还没有清理记录", systemImage: "arrow.uturn.backward.circle",
                                       description: Text("通过收集筐移到废纸篓的项目会记在这里，清空废纸篓之前都可以放回原处。"))
            } else {
                List {
                    ForEach(model.cleanupRecords) { record in
                        Section {
                            ForEach(record.items) { item in
                                ItemRow(item: item, record: record)
                            }
                        } header: {
                            RecordHeader(record: record)
                        }
                    }
                }
            }
        }
        .onAppear { model.reloadCleanupRecords() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The Trash may have been emptied in Finder meanwhile.
            model.reloadCleanupRecords()
        }
    }
}

private struct RecordHeader: View {
    @Environment(AppModel.self) private var model
    let record: CleanupRecord

    var body: some View {
        let inTrash = record.items.filter { $0.state == .inTrash }
        HStack {
            Text(record.date.formatted(date: .abbreviated, time: .shortened))
            Text("· \(record.items.count) 项 · \(ByteFormat.string(record.totalSize))")
                .foregroundStyle(.secondary)
            Spacer()
            if inTrash.count > 1 {
                Button("全部放回") { model.putBack(inTrash, of: record) }
                    .buttonStyle(.link)
                    .disabled(model.isBusy)
            }
        }
        .font(.callout)
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupRecord.Item
    let record: CleanupRecord

    var body: some View {
        let state = item.state
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(((item.originalPath as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(ByteFormat.string(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Group {
                switch state {
                case .inTrash:
                    Button("放回原处") { model.putBack([item], of: record) }
                        .disabled(model.isBusy)
                case .restored:
                    Label("已放回", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .gone:
                    Text("已不在废纸篓")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if state == .inTrash {
                Button("在废纸篓中显示") { show(item.trashPath) }
            }
            if state == .restored {
                Button("在访达中显示") { show(item.originalPath) }
            }
            Button("拷贝原来的路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.originalPath, forType: .string)
            }
        }
        .help(item.originalPath)
    }

    private func show(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
