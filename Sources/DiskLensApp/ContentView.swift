import AppKit
import DiskLensCore
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccessModel.self) private var access
    @Environment(BackgroundRecording.self) private var recording

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .idle:
                WelcomeView()
            case let .scanning(path, files):
                if let tree = model.tree {
                    MainSplitView(tree: tree)
                } else {
                    ScanningView(path: path, files: files)
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("扫描失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("选择其他文件夹…") { model.chooseFolderAndScan() }
                }
            case .ready:
                if let tree = model.tree {
                    MainSplitView(tree: tree)
                }
            }
        }
        .toolbar { MainToolbar() }
        .navigationTitle(model.tree.map { ($0.rootPath as NSString).abbreviatingWithTildeInPath } ?? "DiskLens")
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: Binding(get: { access.showGuide }, set: { access.showGuide = $0 })) {
            FullDiskAccessGuide()
                .environment(model)
                .environment(access)
                .environment(recording)
        }
        .task { access.showOnFirstLaunchIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access.refresh()
        }
        .alert("操作未完成", isPresented: Binding(get: { model.alertMessage != nil },
                                              set: { if !$0 { model.alertMessage = nil } })) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

private struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.goUp() } label: { Label("上一级", systemImage: "chevron.up") }
                .disabled(!model.canGoUp)
                .help("上一级（⌘↑）")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("主目录") { model.scan(AppModel.homePath) }
                Button("整个磁盘") { model.scan(AppModel.wholeDiskPath) }
                Divider()
                Button("选择文件夹…") { model.chooseFolderAndScan() }
            } label: {
                Label("扫描", systemImage: "magnifyingglass")
            }
            .help("选择要扫描的位置")
            Button { model.rescan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                .disabled(model.tree == nil || model.isBusy)
                .help("只重新读取改动过的文件夹（⌘R）；完整重新扫描用 ⇧⌘R")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "internaldrive")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("看看磁盘空间都去哪了")
                    .font(.title.weight(.semibold))
                Text("扫描后可以逐层查看每个文件夹的大小，把不需要的东西放进收集筐统一移到废纸篓。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 12) {
                Button { model.scan(AppModel.homePath) } label: {
                    Label("扫描主目录", systemImage: "house")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                Button { model.scan(AppModel.wholeDiskPath) } label: {
                    Label("扫描整个磁盘", systemImage: "internaldrive")
                        .frame(minWidth: 120)
                }
                Button { model.chooseFolderAndScan() } label: {
                    Label("选择文件夹…", systemImage: "folder")
                        .frame(minWidth: 120)
                }
            }
            .controlSize(.large)
            FullDiskAccessHint()
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FullDiskAccessHint: View {
    @Environment(AccessModel.self) private var access

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if access.isGranted {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("已获得完全磁盘访问权限，可以扫描到邮件、信息、废纸篓等受保护的位置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("要扫描邮件、信息、废纸篓等受保护的位置，需要为 DiskLens 打开“完全磁盘访问权限”。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("开启…") { access.showGuide = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

struct ScanningView: View {
    @Environment(AppModel.self) private var model
    let path: String
    let files: Int

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("正在扫描 \((path as NSString).abbreviatingWithTildeInPath)")
                .font(.headline)
            Text("已发现 \(files.formatted()) 个文件")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("取消") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let tree: FileTree

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Breadcrumb()
                Spacer(minLength: 8)
                if case let .scanning(_, files) = model.phase {
                    ScanStatus(files: files)
                } else if model.isUpdating {
                    UpdateStatus(savedAt: model.showingSavedScanFrom)
                } else if let volume = model.volume {
                    VolumeBar(volume: volume)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if !model.isScanning && tree.stats.unreadableDirectories > 0 {
                UnreadableBanner(count: tree.stats.unreadableDirectories)
                Divider()
            }
            HSplitView {
                FolderTable()
                    .frame(minWidth: 340, idealWidth: 460)
                TreemapPane()
                    .frame(minWidth: 380)
            }
        }
    }
}

/// The browsing window once there is something to show: a sidebar to switch
/// between the space overview and the cleanup suggestions, and the basket below both.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let tree: FileTree

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Label("概览", systemImage: "square.grid.2x2")
                    .tag(AppModel.Section.overview)
                Label("清理建议", systemImage: "sparkles")
                    .badge(cleanupBadge)
                    .tag(AppModel.Section.cleanup)
                Label("大文件", systemImage: "doc.text.magnifyingglass")
                    .tag(AppModel.Section.largeFiles)
                Label("重复文件", systemImage: "doc.on.doc")
                    .badge(duplicatesBadge)
                    .tag(AppModel.Section.duplicates)
                Label("变化", systemImage: "clock.arrow.circlepath")
                    .badge(model.comparison.flatMap { abs($0.delta) >= 1_000_000 ? Text($0.delta.signedBytes) : nil })
                    .tag(AppModel.Section.changes)
                Label("空间时间线", systemImage: "chart.bar.xaxis")
                    .tag(AppModel.Section.timeline)
                Label("存储详情", systemImage: "internaldrive")
                    .tag(AppModel.Section.storage)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                switch model.section {
                case .overview:
                    BrowserView(tree: tree)
                case .cleanup:
                    SuggestionsView()
                case .largeFiles:
                    LargeFilesView()
                case .changes:
                    ChangesView()
                case .timeline:
                    TimelineView()
                case .duplicates:
                    DuplicatesView()
                case .storage:
                    StorageView()
                }
                Divider()
                BasketBar()
            }
        }
    }

    @AppStorage("duplicates.minimumSize") private var duplicatesMinimumSize = 1_000_000
    @AppStorage("duplicates.includeLibrary") private var duplicatesIncludeLibrary = false

    private var duplicatesBadge: Text? {
        guard let groups = model.duplicateGroups, !model.duplicatesAreStale else { return nil }
        let reclaimable = DuplicatesView.narrowed(groups, in: tree, minimumSize: Int64(duplicatesMinimumSize),
                                                  includeLibrary: duplicatesIncludeLibrary)
            .filter { !$0.isMostlyClones }
            .reduce(Int64(0)) { $0 + $1.reclaimable }
        return Text(ByteFormat.string(reclaimable))
    }

    private var cleanupBadge: Text? {
        let total = model.suggestions.filter { $0.action == .trash && $0.safety != .info }
            .reduce(Int64(0)) { $0 + $1.totalSize }
        return total > 0 ? Text(ByteFormat.string(total)) : nil
    }
}

private struct Breadcrumb: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tree = model.tree {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.element) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        let isLast = node == model.breadcrumb.last
                        Button {
                            model.goTo(node)
                        } label: {
                            Text(node == 0 ? (tree.rootPath as NSString).abbreviatingWithTildeInPath : tree.names[node])
                                .fontWeight(isLast ? .semibold : .regular)
                                .foregroundStyle(isLast ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                    Text(ByteFormat.string(tree.totalSizes[model.current]))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }
        }
    }
}

private struct ScanStatus: View {
    @Environment(AppModel.self) private var model
    let files: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("正在扫描 · 已发现 \(files.formatted()) 个文件")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("取消") { model.cancelScan() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// Shown while a saved or current result is brought up to date.
private struct UpdateStatus: View {
    let savedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Group {
                if let savedAt {
                    Text("正在更新 · 显示的是 \(savedAt, format: .relative(presentation: .named))的结果")
                } else {
                    Text("正在更新…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help("只重新读取上次扫描后改动过的文件夹")
    }
}

private struct VolumeBar: View {
    let volume: VolumeInfo

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let total = max(Double(volume.total), 1)
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * Double(volume.used) / total)
                    Rectangle().fill(Color.accentColor.opacity(0.35))
                        .frame(width: geo.size.width * Double(volume.purgeable) / total)
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(width: 180, height: 8)
            Text("已用 \(ByteFormat.string(volume.used)) · 可清除 \(ByteFormat.string(volume.purgeable)) · 可用 \(ByteFormat.string(volume.available))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("\(volume.name)：共 \(ByteFormat.string(volume.total))。“可清除”是 macOS 在空间不足时会自动释放的缓存和快照。")
    }
}

private struct UnreadableBanner: View {
    @Environment(AccessModel.self) private var access
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: access.isGranted ? "arrow.clockwise.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(access.isGranted ? Color.accentColor : Color.yellow)
            Text(access.isGranted
                 ? "已获得完全磁盘访问权限。完整扫描一次，就能包括之前读不到的 \(count) 个文件夹。"
                 : "有 \(count) 个文件夹因为没有权限没能读取，结果可能偏小。")
                .font(.callout)
            Spacer()
            if access.isGranted {
                Button("完整重新扫描") { model.fullRescan() }
                    .font(.callout)
                    .disabled(model.isBusy)
            } else {
                Button("开启完全磁盘访问权限…") { access.showGuide = true }
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }
}
