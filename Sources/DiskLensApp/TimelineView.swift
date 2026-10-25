import Charts
import DiskLensCore
import SwiftUI

/// How the disk's used space changed over time, and who caused it, from the
/// background agent's records.
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Environment(BackgroundRecording.self) private var recording
    @State private var range: Range = .week
    @State private var selectedDate: Date?
    @State private var data = TimelineData()

    enum Range: String, CaseIterable, Identifiable {
        case day, week, month

        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: "24 小时"
            case .week: "7 天"
            case .month: "30 天"
            }
        }
        var span: Int64 {
            switch self {
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
        var bucket: Int64 { self == .day ? 3_600 : 86_400 }
        var unit: Calendar.Component { self == .day ? .hour : .day }
    }

    /// The bucket the user clicked, or the whole range.
    private var detailRange: (start: Int64, end: Int64, title: String) {
        let end = Int64(Date().timeIntervalSince1970)
        if let selectedDate {
            let time = Int64(selectedDate.timeIntervalSince1970)
            let start = bucketStart(of: time)
            let format: Date.FormatStyle = range == .day
                ? .dateTime.month().day().hour() : .dateTime.month().day().weekday()
            return (start, start + range.bucket, Date(timeIntervalSince1970: TimeInterval(start)).formatted(format))
        }
        return (end - range.span, end, "最近 \(range.title)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let message = recording.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if recording.status == .requiresApproval {
                    approvalBanner
                }
                Picker("范围", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                if data.points.isEmpty {
                    ContentUnavailableView {
                        Label("还没有记录", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text(recording.isOn
                             ? "后台记录已开启，每分钟记录一次，稍后这里会出现数据。"
                             : "开启后台记录后，DiskLens 会在后台记下每天的空间变化和写入磁盘最多的应用。")
                    }
                    .frame(minHeight: 220)
                } else {
                    chart
                    details
                }
                Text("“写入量”包括反复覆盖同一个文件，不等于多占的空间；运行时间很短的命令行程序统计不到，但它们造成的空间变化会出现在“增长来源”里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .task(id: TaskKey(range: range, selected: selectedDate.map { bucketStart(of: Int64($0.timeIntervalSince1970)) })) {
            await load()
        }
        .task {
            // Fresh minutes keep arriving while the page is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                recording.refresh()
                await load()
            }
        }
        .onChange(of: range) { selectedDate = nil }
    }

    private struct TaskKey: Equatable {
        let range: Range
        let selected: Int64?
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("空间时间线")
                    .font(.title2.weight(.semibold))
                Text(statusLine)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("后台记录", isOn: Binding(get: { recording.isOn }, set: { recording.setOn($0) }))
                .toggleStyle(.switch)
                .help("登录后在后台运行，CPU 占用约 1%，记录保留 90 天，数据只存在这台 Mac 上")
        }
    }

    private var statusLine: String {
        switch recording.status {
        case .enabled:
            if let last = data.lastRecord {
                return "正在后台记录 · 最近一次 \(last.formatted(.relative(presentation: .named)))"
            }
            return "正在后台记录"
        case .requiresApproval:
            return "等待在系统设置中允许"
        default:
            return data.lastRecord == nil ? "后台记录未开启" : "后台记录已关闭，下面是之前的记录"
        }
    }

    private var approvalBanner: some View {
        HStack {
            Image(systemName: "lock.shield")
            Text("需要在“系统设置 › 通用 › 登录项”中允许 DiskLens 在后台运行。")
            Spacer()
            Button("打开系统设置") { recording.openLoginItemsSettings() }
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var chart: some View {
        let scale = data.points.map { abs($0.change) }.max() ?? 0
        let unit: (divisor: Double, label: String) = scale >= 1_000_000_000 ? (1e9, "GB") : (1e6, "MB")
        return VStack(alignment: .leading, spacing: 6) {
            Text("已用空间的变化（\(unit.label)）")
                .font(.headline)
            Chart(data.points, id: \.time) { point in
                BarMark(x: .value("时间", Date(timeIntervalSince1970: TimeInterval(point.time)), unit: range.unit),
                        y: .value("变化", Double(point.change) / unit.divisor))
                    .foregroundStyle(point.change > 0 ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
                    .opacity(selectedBucket == nil || selectedBucket == point.time ? 1 : 0.35)
            }
            .chartXSelection(value: $selectedDate)
            // Always the whole range, so a few days of data still read as "recent".
            .chartXScale(domain: rangeStart...Date())
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(v, format: .number.precision(.fractionLength(0...1))) } }
                }
            }
            .frame(height: 200)
            if selectedDate != nil {
                Button("显示整个范围") { selectedDate = nil }
                    .buttonStyle(.link)
            }
        }
    }

    private var rangeStart: Date {
        let start = Date().addingTimeInterval(-TimeInterval(range.span))
        return range.unit == .day ? Calendar.current.startOfDay(for: start) : start
    }

    private var selectedBucket: Int64? {
        selectedDate.map { bucketStart(of: Int64($0.timeIntervalSince1970)) }
    }

    private var details: some View {
        let net = data.points.filter { selectedBucket == nil || $0.time == selectedBucket }
            .reduce(Int64(0)) { $0 + $1.change }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(detailRange.title)：已用空间 \(net.signedBytes)")
                .font(.headline)
                .monospacedDigit()
            HStack(alignment: .top, spacing: 16) {
                GroupBox("增长来源") {
                    if data.owners.isEmpty {
                        Text("没有记录到明显的变化").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(data.owners, id: \.app) { owner in
                                OwnerRow(owner: owner, start: detailRange.start, end: detailRange.end)
                            }
                        }
                    }
                }
                GroupBox("写入最多的应用") {
                    if data.writers.isEmpty {
                        Text("没有记录到写入").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(data.writers, id: \.app) { writer in
                                HStack {
                                    Text(writer.app).lineLimit(1)
                                    Spacer()
                                    Text(ByteFormat.string(writer.bytes))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bucketStart(of time: Int64) -> Int64 {
        // Days start at local midnight, not at midnight UTC.
        if range.bucket == 86_400 {
            let date = Date(timeIntervalSince1970: TimeInterval(time))
            return Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        }
        return time / range.bucket * range.bucket
    }

    private func load() async {
        let detail = detailRange
        let range = range
        let offset = Int64(TimeZone.current.secondsFromGMT())
        data = await Task.detached(priority: .userInitiated) {
            guard let store = try? ActivityStore() else { return TimelineData() }
            let end = Int64(Date().timeIntervalSince1970)
            // Daily bars start at local midnight.
            let points = store.volumeSeries(from: end - range.span, to: end, bucket: range.bucket,
                                            offset: range.bucket == 86_400 ? offset : 0)
            return TimelineData(
                points: points,
                owners: store.growthByOwner(from: detail.start, to: detail.end),
                writers: store.topWriters(from: detail.start, to: detail.end),
                lastRecord: store.lastRecord().map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }.value
    }
}

struct TimelineData {
    var points: [ActivityStore.VolumePoint] = []
    var owners: [ActivityStore.WriteTotal] = []
    var writers: [ActivityStore.WriteTotal] = []
    var lastRecord: Date?
}

/// An owner with its net growth; expands to the folders behind it.
private struct OwnerRow: View {
    @Environment(AppModel.self) private var model
    let owner: ActivityStore.WriteTotal
    let start: Int64
    let end: Int64
    @State private var folders: [ActivityStore.Growth] = []
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(folders, id: \.folder) { folder in
                HStack {
                    Text((folder.folder as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(folder.bytes.signedBytes)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.folder)])
                    }
                }
            }
        } label: {
            HStack {
                Text(displayName).lineLimit(1)
                Spacer()
                Text(owner.bytes.signedBytes)
                    .monospacedDigit()
                    .foregroundStyle(owner.bytes > 0 ? Color.red : Color.green)
            }
        }
        .task(id: expanded) {
            guard expanded else { return }
            let (owner, start, end) = (owner.app, start, end)
            folders = await Task.detached {
                (try? ActivityStore())?.growthFolders(owner: owner, from: start, to: end) ?? []
            }.value
        }
    }

    /// Bundle identifiers read better as app names.
    private var displayName: String {
        owner.app.split(separator: ".").count >= 3 ? model.appName(owner.app) : owner.app
    }
}
