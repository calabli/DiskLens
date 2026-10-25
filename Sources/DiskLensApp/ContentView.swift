import AppKit
import DiskLensCore
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .idle:
                WelcomeView()
            case let .scanning(path, files):
                if let tree = model.tree {
                    BrowserView(tree: tree)
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
                    BrowserView(tree: tree)
                }
            }
        }
        .toolbar { MainToolbar() }
        .navigationTitle(model.tree.map { ($0.rootPath as NSString).abbreviatingWithTildeInPath } ?? "DiskLens")
        .quickLookPreview($model.previewURL)
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
                .disabled(model.tree == nil)
                .help("重新扫描（⌘R）")
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
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("要扫描邮件、信息、废纸篓等受保护的位置，需要在系统设置中为 DiskLens 打开“完全磁盘访问权限”。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("打开设置") { openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
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
            Divider()
            BasketBar()
        }
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
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("有 \(count) 个文件夹因为没有权限没能读取，结果可能偏小。")
                .font(.callout)
            Spacer()
            Button("打开完全磁盘访问权限设置") { openFullDiskAccessSettings() }
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }
}
