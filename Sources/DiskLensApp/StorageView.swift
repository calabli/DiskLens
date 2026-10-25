import DiskLensCore
import SwiftUI

/// Where the whole disk's space goes, including what no scan of your files
/// shows: macOS's own volumes, swap, snapshots and purgeable space.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var breakdown: StorageBreakdown?
    @State private var failed = false

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
    }

    private func segments(_ breakdown: StorageBreakdown) -> [Segment] {
        let volumes = breakdown.volumes
        func used(_ roles: Set<StorageBreakdown.Role>) -> Int64 {
            volumes.filter { roles.contains($0.role) }.reduce(0) { $0 + $1.used }
        }
        let dataUsed = used([.data])
        let scanned = min(model.tree?.totalSize ?? 0, dataUsed)
        let scannedTitle: String = switch model.tree?.rootPath {
        case AppModel.homePath?: "主目录（本次扫描）"
        case AppModel.wholeDiskPath?: "你的数据（本次扫描）"
        default: "所扫描的文件夹"
        }
        var result: [Segment] = []
        if scanned > 0 {
            result.append(Segment(id: "scanned", title: scannedTitle,
                                  detail: "在“概览”里能逐层查看的内容。", size: scanned, color: .accentColor))
        }
        result.append(Segment(
            id: "data-other", title: scanned > 0 ? "数据卷中的其他内容" : "你的数据",
            detail: scanned > 0
                ? "扫描范围以外的应用、其他用户的文件、没有权限读取的文件夹和系统数据。"
                : "应用、所有用户的文件和系统数据。",
            size: max(dataUsed - scanned, 0), color: .blue.opacity(0.45)))
        result.append(Segment(id: "system", title: "macOS 系统",
                              detail: "只读的系统卷，随系统更新变化，无法清理。",
                              size: used([.system]), color: .gray))
        result.append(Segment(id: "support", title: "启动与恢复",
                              detail: "Preboot、Recovery 和 Update 卷：启动、恢复模式和系统更新要用到。",
                              size: used([.preboot, .recovery, .update]), color: .gray.opacity(0.55)))
        result.append(Segment(id: "vm", title: "虚拟内存",
                              detail: "内存不够时用来交换的空间，以及休眠镜像；由系统自动管理。",
                              size: used([.vm]), color: .purple.opacity(0.6)))
        let other = used([.other])
        if other > 0 {
            result.append(Segment(id: "other", title: "其他卷", detail: "同一容器里的其他 APFS 卷。",
                                  size: other, color: .orange.opacity(0.6)))
        }
        result.append(Segment(id: "free", title: "可用", detail: "", size: breakdown.containerFree,
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

                snapshots(breakdown.snapshots)
            }
            .padding(24)
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
