import DiskLensCore
import SwiftUI

/// What grew and shrank since the previous scan of this folder.
struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let comparison = model.comparison {
            List {
                Summary(comparison: comparison)
                    .listRowSeparator(.hidden)
                let grew = comparison.changes.filter { $0.delta > 0 }
                let shrank = comparison.changes.filter { $0.delta < 0 }
                if !grew.isEmpty {
                    Section("变大了") {
                        ForEach(grew) { ChangeRow(change: $0) }
                    }
                }
                if !shrank.isEmpty {
                    Section("变小了") {
                        ForEach(shrank) { ChangeRow(change: $0) }
                    }
                }
                if grew.isEmpty && shrank.isEmpty {
                    Text("没有超过 50 MB 的变化。")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView("还没有可以对比的扫描", systemImage: "clock.arrow.circlepath",
                                   description: Text("再次扫描这个文件夹后，这里会列出两次之间的变化。"))
        }
    }
}

private struct Summary: View {
    let comparison: ScanComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text("上次扫描于 \(comparison.previousDate.formatted(date: .abbreviated, time: .shortened))：\(ByteFormat.string(comparison.previousTotal)) → 现在 \(ByteFormat.string(comparison.currentTotal))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 12)
    }

    private var headline: String {
        let since = comparison.previousDate.formatted(.relative(presentation: .named))
        if comparison.delta == 0 { return "与\(since)相比没有变化" }
        return "比\(since)\(comparison.delta > 0 ? "多了" : "少了") \(ByteFormat.string(abs(comparison.delta)))"
    }
}

private struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let change: ScanChange

    var body: some View {
        let exists = model.tree?.node(atPath: change.path) != nil
        HStack(spacing: 10) {
            Image(systemName: change.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(change.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((change.path as NSString).lastPathComponent)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if change.before == 0 {
                        Tag(text: "新出现", color: .orange)
                    } else if change.after == 0 {
                        Tag(text: "已删除", color: .secondary)
                    }
                }
                Text(displayFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text("\(ByteFormat.string(change.before)) → \(ByteFormat.string(change.after))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(change.delta.signedBytes)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(change.delta > 0 ? Color.red : Color.green)
                .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if exists { model.reveal(path: change.path) } }
        .contextMenu {
            Button("在概览中显示") { model.reveal(path: change.path) }
                .disabled(!exists)
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)])
            }
            .disabled(!exists)
        }
        .help(change.path)
    }

    private var displayFolder: String {
        let folder = (change.path as NSString).deletingLastPathComponent
        return folder.abbreviatingHome
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension Int64 {
    /// "+2.3 GB" or "-512 MB".
    var signedBytes: String {
        (self >= 0 ? "+" : "-") + ByteFormat.string(Swift.abs(self))
    }
}
