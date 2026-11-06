import DiskLensCore
import SwiftUI

/// Where the whole disk's space goes, including what no scan of your files
/// shows: macOS's own volumes, swap, snapshots and purgeable space.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var breakdown: StorageBreakdown?
    @State private var failed = false
    @State private var categories: StorageCategories?

    private struct Segment: Identifiable {
        let id: String
        let title: String
        let detail: String
        let size: Int64
        let color: Color
    }

    var body: some View {
        Group {
            if let breakdown {
                content(breakdown)
            } else if failed {
                ContentUnavailableView("没能读取磁盘信息", systemImage: "exclamationmark.triangle",
                                       description: Text("这台 Mac 的启动磁盘可能不是 APFS 格式。"))
            } else {
                ProgressView("正在读取磁盘信息…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let result = await Task.detached { try? StorageBreakdown.load() }.value
            breakdown = result
            failed = result == nil
        }
        .task(id: "\(model.treeVersion) \(breakdown != nil)") {
            categories = nil
            guard let breakdown, let tree = model.tree, tree.rootPath == AppModel.wholeDiskPath else { return }
            categories = await Task.detached { StorageCategories(tree: tree, breakdown: breakdown) }.value
        }
    }

    private func segments(_ breakdown: StorageBreakdown) -> [Segment] {
        let volumes = breakdown.volumes
        func used(_ roles: Set<StorageBreakdown.Role>) -> Int64 {
            volumes.filter { roles.contains($0.role) }.reduce(0) { $0 + $1.used }
        }
        let dataUsed = used([.data])
        let scanned = min(model.tree?.totalSize ?? 0, dataUsed)
        let scannedTitle: String = switch model.tree?.rootPath {
        case AppModel.homePath?: L("主目录（本次扫描）")
        case AppModel.wholeDiskPath?: L("你的数据（本次扫描）")
        default: L("所扫描的文件夹")
        }
        var result: [Segment] = []
        if scanned > 0 {
            result.append(Segment(id: "scanned", title: scannedTitle,
                                  detail: L("在“概览”里能逐层查看的内容。"), size: scanned, color: .accentColor))
        }
        result.append(Segment(
            id: "data-other", title: scanned > 0 ? L("数据卷中的其他内容") : L("你的数据"),
            detail: scanned > 0
                ? L("扫描范围以外的应用、其他用户的文件、没有权限读取的文件夹和系统数据。")
                : L("应用、所有用户的文件和系统数据。"),
            size: max(dataUsed - scanned, 0), color: .blue.opacity(0.45)))
        result.append(Segment(id: "system", title: L("macOS 系统"),
                              detail: L("只读的系统卷，随系统更新变化，无法清理。"),
                              size: used([.system]), color: .gray))
        result.append(Segment(id: "support", title: L("启动与恢复"),
                              detail: L("Preboot、Recovery 和 Update 卷：启动、恢复模式和系统更新要用到。"),
                              size: used([.preboot, .recovery, .update]), color: .gray.opacity(0.55)))
        result.append(Segment(id: "vm", title: L("虚拟内存"),
                              detail: L("内存不够时用来交换的空间，以及休眠镜像；由系统自动管理。"),
                              size: used([.vm]), color: .purple.opacity(0.6)))
        let other = used([.other])
        if other > 0 {
            result.append(Segment(id: "other", title: L("其他卷"), detail: L("同一容器里的其他 APFS 卷。"),
                                  size: other, color: .orange.opacity(0.6)))
        }
        result.append(Segment(id: "free", title: L("可用"), detail: "", size: breakdown.containerFree,
                              color: Color.primary.opacity(0.08)))
        return result.filter { $0.size > 0 }
    }

    private func content(_ breakdown: StorageBreakdown) -> some View {
        let segments = segments(breakdown)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("磁盘空间都去哪了")
                        .font(.title2.weight(.semibold))
                    Text("共 \(ByteFormat.string(breakdown.containerSize)) · 已用 \(ByteFormat.string(breakdown.containerUsed)) · 可用 \(ByteFormat.string(breakdown.containerFree))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                StackedBar(segments: segments.map { ($0.size, $0.color) }, total: breakdown.containerSize)
                    .frame(height: 22)

                VStack(spacing: 0) {
                    ForEach(segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(segment.color)
                                .frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segment.title).fontWeight(.medium)
                                if !segment.detail.isEmpty {
                                    Text(segment.detail).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(ByteFormat.string(segment.size))
                                .monospacedDigit()
                                .fontWeight(.medium)
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }

                if breakdown.purgeable > 0 {
                    Label {
                        Text("其中约 \(ByteFormat.string(breakdown.purgeable)) 是可清除空间：缓存、本地快照和已同步到 iCloud 的文件等。macOS 会在空间不够时自动释放，Finder 显示的可用空间已经算上了这部分。")
                    } icon: {
                        Image(systemName: "arrow.3.trianglepath")
                    }
                    .foregroundStyle(.secondary)
                }

                if UserHome.demoPath == nil {
                    settingsCategories(breakdown)
                }

                snapshots(breakdown.snapshots)
            }
            .padding(24)
        }
    }

    /// The categories of System Settings › Storage, which need a scan of the whole disk.
    @ViewBuilder
    private func settingsCategories(_ breakdown: StorageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按系统设置的分类")
                .font(.headline)
            if let categories {
                let unreadable = model.tree?.stats.unreadable.contains { $0.needsFullDiskAccess } ?? false
                Text("macOS 没有公开这些分类的算法，这里是按文件夹估算的，和系统设置里的数字接近，但不会完全相同。已减去 \(ByteFormat.string(breakdown.purgeable)) 可清除空间。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if unreadable {
                    Label("有些文件夹没有权限读取，所以应用程序、邮件和照片会偏小，系统数据会偏大。开启完全磁盘访问权限后重新扫描会更准。",
                          systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                VStack(spacing: 0) {
                    ForEach(CategoryRow.all, id: \.title) { row in
                        categoryRow(row, size: categories.sizes[row.category, default: 0])
                    }
                }
                systemData(categories)
            } else if model.isScanning {
                Text("扫描完成后，这里会显示各分类的大小。")
                    .foregroundStyle(.secondary)
            } else {
                Text("系统数据里有什么，要扫描整个磁盘才知道。")
                    .foregroundStyle(.secondary)
                Button("扫描整个磁盘") { model.scan(AppModel.wholeDiskPath) }
            }
        }
    }

    private func categoryRow(_ row: CategoryRow, size: Int64) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(verbatim: row.title)
                    .fontWeight(.medium)
                Spacer()
                Text(ByteFormat.string(size))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            .padding(.vertical, 7)
            Divider()
        }
    }

    /// What System Data is made of, largest first, since that is the category nothing else explains.
    private func systemData(_ categories: StorageCategories) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("系统数据里有什么")
                .font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(partsLargestFirst(categories), id: \.row.title) { row, size in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.title).fontWeight(.medium)
                        Text(verbatim: row.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.canClean {
                        Button("去清理") { model.section = .cleanup }
                    }
                    Text(ByteFormat.string(size))
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }

    /// The parts with something in them, largest first and "other" always last.
    private func partsLargestFirst(_ categories: StorageCategories) -> [(row: SystemPartRow, size: Int64)] {
        let parts: [(row: SystemPartRow, size: Int64)] = SystemPartRow.all.compactMap { row in
            let size = categories.systemParts[row.part, default: 0]
            return size > 0 ? (row, size) : nil
        }
        let named = parts.filter { $0.row.part != .other }.sorted { $0.size > $1.size }
        return named + parts.filter { $0.row.part == .other }
    }

    private struct CategoryRow {
        let category: StorageCategories.Category
        let title: String
        let symbol: String

        static var all: [CategoryRow] {
            [CategoryRow(category: .developer, title: L("开发者"), symbol: "hammer"),
             CategoryRow(category: .documents, title: L("文稿"), symbol: "doc"),
             CategoryRow(category: .applications, title: L("应用程序"), symbol: "app.dashed"),
             CategoryRow(category: .mail, title: L("邮件"), symbol: "envelope"),
             CategoryRow(category: .photos, title: L("照片"), symbol: "photo"),
             CategoryRow(category: .iCloudDrive, title: L("iCloud 云盘"), symbol: "icloud"),
             CategoryRow(category: .otherUsers, title: L("其他用户与共享"), symbol: "person.2"),
             CategoryRow(category: .macOS, title: "macOS", symbol: "laptopcomputer"),
             CategoryRow(category: .systemData, title: L("系统数据"), symbol: "ellipsis.circle")]
        }
    }

    private struct SystemPartRow {
        let part: StorageCategories.SystemPart
        let title: String
        let detail: String
        var canClean = false

        static var all: [SystemPartRow] {
            [SystemPartRow(part: .wallpapers, title: L("动态壁纸"),
                           detail: L("下载到这台 Mac 的动态壁纸和屏保视频。删除后，用到时会重新下载。"), canClean: true),
             SystemPartRow(part: .caches, title: L("缓存"),
                           detail: L("应用和系统的缓存。其中常见的几类可以在清理建议里处理，其余由应用自己管理。"), canClean: true),
             SystemPartRow(part: .systemAssets, title: L("系统资源"),
                           detail: L("字典、语音、翻译、字体等，由 macOS 下载和管理，不能手动清理。")),
             SystemPartRow(part: .temporaryFiles, title: L("临时文件"),
                           detail: L("系统会自动清理。运行中的应用可能正在使用，不建议手动删除。")),
             SystemPartRow(part: .swap, title: L("交换文件"),
                           detail: L("内存不够时使用的交换文件和休眠镜像，由 macOS 管理。")),
             SystemPartRow(part: .databases, title: L("系统数据库"),
                           detail: L("系统的数据库和索引，不能手动清理。")),
             SystemPartRow(part: .logs, title: L("日志"),
                           detail: L("应用和系统的运行记录。"), canClean: true),
             SystemPartRow(part: .commandLineTools, title: L("命令行工具"),
                           detail: L("/usr/local 和 /opt 里的软件，比如用 Homebrew 安装的工具。")),
             SystemPartRow(part: .other, title: L("其他"),
                           detail: L("没有算进上面各项的内容，包括没有权限读取的部分。这一项是估算的。"))]
        }
    }

    private func snapshots(_ snapshots: [StorageBreakdown.Snapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地快照")
                .font(.headline)
            if snapshots.isEmpty {
                Text("没有本地快照。")
                    .foregroundStyle(.secondary)
            } else {
                Text("快照会保住删除前的文件版本，删掉的文件要等快照被移除后才真正释放空间。Time Machine 的本地快照通常 24 小时后自动删除。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(snapshots) { snapshot in
                    HStack {
                        Image(systemName: snapshot.isTimeMachine ? "clock.arrow.circlepath" : "gearshape")
                            .foregroundStyle(.secondary)
                        Text(snapshot.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? snapshot.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if snapshot.isTimeMachine, let command = deleteCommand(for: snapshot) {
                            Button("拷贝删除命令") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            .buttonStyle(.link)
                            .help("\(command)（在“终端”中运行，需要管理员密码）")
                        }
                    }
                }
            }
        }
    }

    private func deleteCommand(for snapshot: StorageBreakdown.Snapshot) -> String? {
        guard let range = snapshot.name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression)
        else { return nil }
        return "sudo tmutil deletelocalsnapshots \(snapshot.name[range])"
    }
}

/// A single bar split into proportional colored segments.
private struct StackedBar: View {
    let segments: [(size: Int64, color: Color)]
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(geo.size.width * Double(segment.size) / Double(max(total, 1)) - 1, 0))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
