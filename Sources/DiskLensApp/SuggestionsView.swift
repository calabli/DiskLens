import AppKit
import DiskLensCore
import SwiftUI

/// Cleanup suggestions in three tiers. Nothing is deleted from here: items go
/// to the basket, which moves them to the Trash after one confirmation.
struct SuggestionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isScanning {
                ContentUnavailableView("扫描完成后给出清理建议", systemImage: "hourglass",
                                       description: Text("建议基于完整的扫描结果。"))
            } else if model.isAnalyzing && model.suggestions.isEmpty {
                ProgressView("正在分析…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failure(error) = AppModel.rules {
                ContentUnavailableView("清理规则没能加载", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if model.suggestions.isEmpty {
                ContentUnavailableView("没有发现可以清理的内容", systemImage: "checkmark.seal",
                                       description: Text("扫描范围内没有匹配的规则。扫描主目录能得到更完整的建议。"))
            } else {
                List {
                    SummaryHeader()
                        .listRowSeparator(.hidden)
                    ForEach(CleanupSafety.allCases, id: \.self) { safety in
                        let group = model.suggestions.filter { $0.safety == safety }
                        if !group.isEmpty {
                            Section {
                                ForEach(group) { SuggestionRow(suggestion: $0) }
                            } header: {
                                TierHeader(safety: safety, total: group.reduce(0) { $0 + $1.totalSize })
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { model.refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshRunningApps()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshRunningApps()
        }
    }
}

private struct SummaryHeader: View {
    @Environment(AppModel.self) private var model

    private var trashable: [CleanupSuggestion] {
        model.suggestions.filter { $0.action == .trash && $0.safety != .info }
    }

    /// Safe items whose apps are not running and that are not already in the basket.
    private var readySafeItems: [CleanupItem] {
        model.suggestions
            .filter { $0.safety == .safe && $0.action == .trash && model.runningApps(for: $0).isEmpty }
            .flatMap(\.items)
            .filter { !model.isInBasket($0.node) }
    }

    var body: some View {
        let total = trashable.reduce(Int64(0)) { $0 + $1.totalSize }
        let safe = trashable.filter { $0.safety == .safe }.reduce(Int64(0)) { $0 + $1.totalSize }
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("可以释放约 \(ByteFormat.string(total))")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("其中 \(ByteFormat.string(safe)) 是缓存和可以自动重建的内容，可以放心清理。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.addToBasket(readySafeItems)
            } label: {
                Label("全部加入收集筐", systemImage: "tray.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(readySafeItems.isEmpty)
            .help("把“可放心清理”中的所有项目加入收集筐（对应应用正在运行的除外）")
        }
        .padding(.vertical, 12)
    }
}

private struct TierHeader: View {
    let safety: CleanupSafety
    let total: Int64

    var body: some View {
        HStack {
            Label(safety.title, systemImage: safety.symbol)
                .foregroundStyle(safety.tint)
            Text(safety.subtitle)
                .foregroundStyle(.secondary)
                .fontWeight(.regular)
            Spacer()
            Text(ByteFormat.string(total))
                .monospacedDigit()
        }
        .font(.headline)
        .padding(.top, 8)
    }
}

private struct SuggestionRow: View {
    @Environment(AppModel.self) private var model
    let suggestion: CleanupSuggestion
    @State private var expanded = false

    var body: some View {
        let running = model.runningApps(for: suggestion)
        let pending = suggestion.items.filter { !model.isInBasket($0.node) }
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(suggestion.items) { item in
                ItemRow(item: item, canAdd: suggestion.action == .trash && running.isEmpty)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: suggestion.category.symbol)
                    .font(.title3)
                    .foregroundStyle(suggestion.safety.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(suggestion.title)
                            .font(.headline)
                        if suggestion.regenerable {
                            Text("可自动重建")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                    Text(suggestion.explanation)
                        .foregroundStyle(.secondary)
                    Text("删除后：\(suggestion.consequence)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !running.isEmpty {
                        Label("\(running.map(model.appName).joined(separator: "、")) 正在运行，请先退出再清理",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if let command = suggestion.command {
                        CommandLine(command: command)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(ByteFormat.string(suggestion.totalSize))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    if suggestion.items.count > 1 {
                        Text("\(suggestion.items.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if suggestion.action == .trash {
                        Button(pending.isEmpty ? "已在收集筐中" : "加入收集筐") {
                            model.addToBasket(pending)
                        }
                        .disabled(pending.isEmpty || !running.isEmpty)
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } }
        }
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem
    let canAdd: Bool

    var body: some View {
        let inBasket = model.isInBasket(item.node)
        HStack(spacing: 8) {
            Text(item.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(inBasket ? 0.45 : 1)
            if let date = item.lastModified {
                Text("最后改动 \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if canAdd {
                Button {
                    model.addToBasket(item.node)
                } label: {
                    Image(systemName: inBasket ? "checkmark.circle.fill" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(inBasket)
                .help(inBasket ? "已在收集筐中" : "加入收集筐")
            }
        }
        .padding(.leading, 38)
        .help(model.tree.map { $0.path(of: item.node) } ?? "")
        .contextMenu {
            Button("在 Finder 中显示") { model.revealInFinder(item.node) }
            Button("拷贝路径") { model.copyPath(item.node) }
            if canAdd && !inBasket {
                Divider()
                Button("加入收集筐") { model.addToBasket(item.node) }
            }
        }
    }
}

/// A command to run in Terminal instead of deleting files, with a copy button.
private struct CommandLine: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            Button(copied ? "已拷贝" : "拷贝命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }
}

extension CleanupSafety {
    var title: String {
        switch self {
        case .safe: "可放心清理"
        case .review: "建议检查"
        case .info: "仅供参考"
        }
    }

    var subtitle: String {
        switch self {
        case .safe: "缓存和可以自动重建的内容"
        case .review: "可能还有用，请逐项确认"
        case .info: "不宜直接删除文件，按说明处理"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.seal.fill"
        case .review: "eye.fill"
        case .info: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .info: .secondary
        }
    }
}

extension CleanupCategory {
    var symbol: String {
        switch self {
        case .developer: "hammer"
        case .system: "gearshape"
        case .apps: "app.badge"
        case .chat: "bubble.left.and.bubble.right"
        case .backups: "externaldrive"
        case .projects: "folder.badge.gearshape"
        case .leftovers: "shippingbox"
        }
    }
}
