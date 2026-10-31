import DiskLensCore
import SwiftUI

/// Installed toolchains, simulators, images and caches by ecosystem, with what
/// each takes, whether it is still in use, and a safe way to remove it.
struct DevToolsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: DevItem?

    private var tools: DevToolsModel { model.devTools }

    var body: some View {
        let groups = DevEcosystem.allCases.compactMap { tools.groups[$0] }
        VStack(spacing: 0) {
            Header(groups: groups)
            Divider()
            List {
                // Ecosystems found to have nothing are named once at the end instead of each taking a section.
                ForEach(DevEcosystem.allCases.filter { tools.groups[$0].map { !$0.items.isEmpty } ?? true }, id: \.self) { ecosystem in
                    Section {
                        if let group = tools.groups[ecosystem] {
                            if let note = group.note {
                                Text(note)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.items) { item in
                                DevItemRow(item: item, confirm: { confirming = item })
                            }
                        }
                    } header: {
                        GroupHeader(ecosystem: ecosystem, group: tools.groups[ecosystem],
                                    loading: tools.loading.contains(ecosystem))
                    }
                }
                let missing = DevEcosystem.allCases.filter { tools.groups[$0]?.items.isEmpty == true }
                if !missing.isEmpty {
                    Text("没有检测到：" + missing.map(\.title).joined(separator: "、"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: model.treeGeneration) {
            tools.refreshIfNeeded(tree: model.tree, generation: model.treeGeneration)
        }
        .sheet(item: $confirming) { item in
            RunCommandSheet(item: item)
                .environment(model)
        }
    }
}

private struct Header: View {
    @Environment(AppModel.self) private var model
    let groups: [DevGroup]

    var body: some View {
        let items = groups.flatMap(\.items)
        let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let unused = items.filter { if case .unused = $0.usage { true } else { false } }
            .reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("开发工具共占 \(ByteFormat.string(total))")
                    .font(.title3.weight(.semibold))
                Text(unused > 0 ? "其中 \(ByteFormat.string(unused)) 看起来已经不用了。删除前会告诉你后果，能用工具自己的命令就用它的命令。"
                                : "能用工具自己的命令删除的，DiskLens 会用它的命令，不直接删文件。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.devTools.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                model.devTools.refresh(tree: model.tree)
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
            }
            .disabled(model.devTools.isLoading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct GroupHeader: View {
    let ecosystem: DevEcosystem
    let group: DevGroup?
    let loading: Bool

    var body: some View {
        HStack {
            Text(ecosystem.title)
            if loading {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let group, group.totalSize > 0 {
                Text(ByteFormat.string(group.totalSize))
                    .monospacedDigit()
            }
        }
    }
}

private struct DevItemRow: View {
    @Environment(AppModel.self) private var model
    let item: DevItem
    let confirm: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(item.kind)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    UsageBadge(usage: item.usage)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let lastUsed = item.lastUsed {
                Text(lastUsed, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("最后使用：" + lastUsed.formatted(date: .long, time: .shortened))
            }
            Text(item.size.map(ByteFormat.string) ?? "—")
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            action
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let path = item.path {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("拷贝路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            if case let .command(command) = item.removal {
                Button("拷贝命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command.display, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch item.removal {
        case .command:
            Button(model.devTools.running == item.id ? "正在删除…" : "删除…", action: confirm)
                .disabled(model.devTools.running != nil)
        case let .trash(path):
            if model.isInBasket(path: path) {
                Text("已在收集筐中")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("加入收集筐") { model.addToBasket(path: path, size: item.size ?? 0) }
                    .disabled(item.isActive)
                    .help(item.isActive ? "正在使用，不能删除" : item.consequence)
            }
        case let .none(reason):
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(reason)
        }
    }
}

private struct UsageBadge: View {
    let usage: DevItem.Usage

    var body: some View {
        switch usage {
        case let .active(text): badge(text, .accentColor)
        case let .used(text): badge(text, .green)
        case let .unused(text): badge(text, .orange)
        case let .regenerable(text): badge(text, .secondary)
        case .unknown: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}

/// Shows exactly what will run and what it means, runs it, then shows what the tool printed.
private struct RunCommandSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: DevItem

    var body: some View {
        let tools = model.devTools
        let result = tools.lastRun.flatMap { $0.item.id == item.id ? $0 : nil }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("删除\(item.kind)：\(item.title)")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if let size = item.size {
                        Text("约 \(ByteFormat.string(size))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(item.consequence)
            if case let .active(text) = item.usage {
                Label("\(text)。删除后用到它的地方会出错。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if case let .used(text) = item.usage {
                Label("\(text)，删除后需要时会重新下载或生成。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let command {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DiskLens 会运行这条命令：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(command.display)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let result {
                Label(result.succeeded ? "已完成，记在了清理记录里。" : "命令没有成功。",
                      systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                ScrollView {
                    Text(String(result.output.suffix(6000)))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Spacer()
                if result != nil {
                    Button("完成") {
                        tools.dismissResult()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else if tools.running == item.id {
                    ProgressView().controlSize(.small)
                    Text("正在运行…").foregroundStyle(.secondary)
                } else {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("运行") {
                        guard let command else { return }
                        tools.run(command, for: item, tree: model.tree) { succeeded in
                            guard succeeded else { return }
                            model.reloadCleanupRecords()
                            if model.tree != nil && !model.isBusy { model.rescan() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var command: ToolCommand? {
        if case let .command(command) = item.removal { command } else { nil }
    }
}

extension DevItem {
    var isActive: Bool {
        if case .active = usage { true } else { false }
    }
}
