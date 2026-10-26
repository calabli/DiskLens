import AppKit
import DiskLensCore
import Observation
import SwiftUI

/// Installed apps and everything each one keeps on disk.
@MainActor @Observable
final class AppUninstaller {
    private(set) var apps: [InstalledApp] = []
    private(set) var footprints: [String: AppFootprint] = [:]
    private(set) var lastUsed: [String: Date] = [:]
    private(set) var isLoading = false
    /// The app shown in detail, by path.
    var selection: String?
    @ObservationIgnored private var loadedFor = -1

    /// Reads the installed apps, then measures them one by one in the background.
    func load(tree: FileTree?, generation: Int, force: Bool = false) {
        guard force || generation != loadedFor else { return }
        loadedFor = generation
        isLoading = true
        Task {
            let apps = await Task.detached(priority: .userInitiated) { AppCatalog.installedApps() }.value
            self.apps = apps
            footprints = footprints.filter { key, _ in apps.contains { $0.path == key } }
            var finder = AppFootprintFinder(installed: apps)
            // Sizes the scan already knows come from it; the rest are measured.
            finder.sizeOf = { path in
                if let tree, let node = tree.node(atPath: path) { return tree.totalSizes[node] }
                return AppFootprintFinder.measure(path)
            }
            for app in apps {
                let footprint = await Task.detached(priority: .utility) { finder.footprint(of: app) }.value
                footprints[app.path] = footprint
            }
            lastUsed = await Task.detached(priority: .utility) {
                var dates: [String: Date] = [:]
                for app in apps { dates[app.path] = LargeFileFinder.lastUsedDate(ofFileAt: app.path) }
                return dates
            }.value
            isLoading = false
        }
    }

    func reload(tree: FileTree?) {
        load(tree: tree, generation: loadedFor, force: true)
    }

    /// Re-measures one app, e.g. after it was quit.
    func refresh(_ app: InstalledApp, tree: FileTree?) {
        var finder = AppFootprintFinder(installed: apps)
        finder.sizeOf = { path in
            if let tree, let node = tree.node(atPath: path) { return tree.totalSizes[node] }
            return AppFootprintFinder.measure(path)
        }
        let measured = finder
        Task {
            footprints[app.path] = await Task.detached { measured.footprint(of: app) }.value
        }
    }
}

private struct AppRow: Identifiable {
    let app: InstalledApp
    let appSize: Int64
    let dataSize: Int64
    let lastUsed: Date
    var id: String { app.path }
    var name: String { app.name }
    var total: Int64 { appSize + dataSize }
}

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUninstaller.self) private var uninstaller
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\AppRow.total, order: .reverse)]

    private var rows: [AppRow] {
        uninstaller.apps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) }
            .map { app in
                let footprint = uninstaller.footprints[app.path]
                return AppRow(app: app, appSize: footprint?.files.first?.size ?? 0, dataSize: footprint?.dataSize ?? 0,
                              lastUsed: uninstaller.lastUsed[app.path] ?? .distantPast)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索应用", text: $search)
                        .textFieldStyle(.plain)
                    if uninstaller.isLoading {
                        ProgressView().controlSize(.small)
                        Text("正在计算 \(uninstaller.footprints.count)/\(uninstaller.apps.count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                table
            }
            .frame(minWidth: 520, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            Group {
                if let path = uninstaller.selection, let app = uninstaller.apps.first(where: { $0.path == path }) {
                    AppDetail(app: app, footprint: uninstaller.footprints[path])
                        .id(path)
                } else {
                    ContentUnavailableView("选择一个应用", systemImage: "app.dashed",
                                           description: Text("查看它在磁盘上的全部文件：应用本身、数据、缓存、设置和后台程序。"))
                }
            }
            .frame(minWidth: 380, idealWidth: 420, maxHeight: .infinity)
        }
        // Fill the page: without this the split view takes the height of its shortest
        // content (the empty-selection placeholder) and sits at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.treeGeneration) {
            uninstaller.load(tree: model.tree, generation: model.treeGeneration)
        }
        .onChange(of: model.externalItemsRecycled) {
            uninstaller.reload(tree: model.tree)
        }
    }

    private var table: some View {
        @Bindable var uninstaller = uninstaller
        return Table(rows, selection: $uninstaller.selection, sortOrder: $sortOrder) {
            TableColumn("应用", value: \.name) { row in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(row.name).lineLimit(1)
                    if model.isInBasket(path: row.app.path) {
                        Image(systemName: "tray.full").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(row.app.isSystemApp ? 0.55 : 1)
            }
            .width(min: 140, ideal: 180)
            TableColumn("应用", value: \.appSize) { row in
                SizeText(bytes: row.appSize, known: uninstaller.footprints[row.id] != nil)
            }
            .width(min: 60, ideal: 68)
            TableColumn("相关数据", value: \.dataSize) { row in
                SizeText(bytes: row.dataSize, known: uninstaller.footprints[row.id] != nil)
            }
            .width(min: 64, ideal: 76)
            TableColumn("合计", value: \.total) { row in
                SizeText(bytes: row.total, known: uninstaller.footprints[row.id] != nil)
                    .fontWeight(.medium)
            }
            .width(min: 64, ideal: 76)
            TableColumn("上次使用", value: \.lastUsed) { row in
                Text(row.lastUsed == .distantPast ? "—"
                     : row.lastUsed.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 76, ideal: 88)
        }
    }
}

private struct SizeText: View {
    let bytes: Int64
    let known: Bool

    var body: some View {
        Text(known ? ByteFormat.string(bytes) : "…")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One app's files, grouped by where they live, ready to go to the basket.
private struct AppDetail: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp
    let footprint: AppFootprint?
    /// Overrides of the default choice (certain: on, likely: off), by path.
    @State private var choices: [String: Bool] = [:]
    @State private var running: [NSRunningApplication] = []
    @State private var copied = false

    private func isChosen(_ file: AppFile) -> Bool {
        !file.requiresAdmin && (choices[file.path] ?? (file.confidence == .certain))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let footprint {
                List {
                    ForEach(groups(footprint), id: \.kind) { group in
                        Section(group.kind.title) {
                            ForEach(group.files) { file in fileRow(file) }
                        }
                    }
                    if let command = footprint.adminCommand {
                        Section("需要管理员权限") {
                            Text("下面这些在系统资源库里，DiskLens 不能直接移到废纸篓。需要时在“终端”里运行（会要求输入管理员密码）：")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            Button(copied ? "已拷贝" : "拷贝命令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = true
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ProgressView("正在查找相关文件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            running = NSWorkspace.shared.runningApplications.filter {
                guard let id = $0.bundleIdentifier else { return false }
                return app.allIDs.contains(id)
            }
        }
    }

    private var header: some View {
        let chosen = footprint?.files.filter(isChosen) ?? []
        let chosenSize = chosen.reduce(Int64(0)) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.weight(.semibold))
                    Text([app.version.map { "版本 \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let footprint {
                        Text("应用 \(ByteFormat.string(footprint.files[0].size)) · 相关数据 \(ByteFormat.string(footprint.dataSize))")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if app.isSystemApp {
                Label("macOS 自带的应用，在只读的系统卷上，无法删除。", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else {
                if !running.isEmpty {
                    HStack {
                        Label("\(app.name) 正在运行，卸载前请先退出。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("退出 \(app.name)") {
                            running.forEach { $0.terminate() }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                running = running.filter { !$0.isTerminated }
                            }
                        }
                    }
                }
                if app.isApple {
                    Label("Apple 的应用。卸载后可以在 App Store 重新下载。", systemImage: "applelogo")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("已选 \(chosen.count) 项 · \(ByteFormat.string(chosenSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        for file in chosen { model.addToBasket(path: file.path, size: file.size) }
                    } label: {
                        Label("卸载：加入收集筐", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || !running.isEmpty || model.isBusy)
                    .help("确认后在收集筐里一起移到废纸篓，之后还能从废纸篓恢复")
                }
            }
        }
        .padding(16)
    }

    private func fileRow(_ file: AppFile) -> some View {
        HStack(spacing: 10) {
            if file.requiresAdmin {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 18)
            } else {
                Toggle("", isOn: Binding(get: { isChosen(file) }, set: { choices[file.path] = $0 }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(app.isSystemApp)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.path.hasPrefix("pkg:") ? String(file.path.dropFirst(4)) : (file.path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.confidence == .likely {
                        Text("可能相关")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(file.path.hasPrefix("pkg:") ? file.reason
                     : "\(file.reason) · \((file.path as NSString).deletingLastPathComponent.abbreviatingHome)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormat.string(file.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            if !file.path.hasPrefix("pkg:") {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                }
            }
        }
        .help(file.path)
    }

    private func groups(_ footprint: AppFootprint) -> [(kind: AppFile.Kind, files: [AppFile])] {
        AppFile.Kind.allCases.compactMap { kind in
            let files = footprint.files.filter { $0.kind == kind && !$0.requiresAdmin }
            return files.isEmpty ? nil : (kind, files)
        } + {
            let admin = footprint.files.filter(\.requiresAdmin)
            return admin.isEmpty ? [] : [(AppFile.Kind.systemLaunchItem, admin)]
        }()
    }
}

extension AppFile.Kind {
    var title: String {
        switch self {
        case .app: "应用"
        case .container: "沙盒容器"
        case .groupContainer: "共享容器"
        case .support: "应用数据"
        case .caches: "缓存"
        case .preferences: "设置"
        case .savedState: "窗口状态"
        case .webData: "网页数据"
        case .logs: "日志"
        case .crashReports: "崩溃报告"
        case .scripts: "脚本"
        case .launchAgent: "后台程序"
        case .systemLaunchItem: "系统级后台程序（需要管理员）"
        case .privilegedHelper: "辅助工具（需要管理员）"
        case .installedFiles: "安装记录（需要管理员）"
        }
    }
}
