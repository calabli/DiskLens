import DiskLensCore
import SwiftUI

/// The panel that opens from the menu bar item.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(SpaceMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let volume = monitor.volume {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(volume.name).font(.headline)
                        Spacer()
                        Text("可用 \(ByteFormat.string(volume.availableForImportantUsage))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(volume: volume)
                        .frame(height: 8)
                    Text("已用 \(ByteFormat.string(volume.used)) · 其中可清除 \(ByteFormat.string(volume.purgeable)) · 共 \(ByteFormat.string(volume.total))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let change = monitor.todayChange {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今天 \(change.signedBytes)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(change > 0 ? Color.red : Color.green)
                    ForEach(monitor.todaySources, id: \.app) { source in
                        HStack {
                            Text(source.app.split(separator: ".").count >= 3 ? model.appName(source.app) : source.app)
                                .lineLimit(1)
                            Spacer()
                            Text(source.bytes.signedBytes).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text("开启“空间时间线”里的后台记录后，这里会显示今天的变化。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuButton(title: "打开 DiskLens", symbol: "macwindow") { show(nil) }
                MenuButton(title: "扫描主目录", symbol: "house") {
                    show(.overview)
                    model.scan(AppModel.homePath)
                }
                MenuButton(title: "清理建议", symbol: "sparkles") {
                    show(.cleanup)
                    if model.tree == nil { model.scan(AppModel.homePath) }
                }
                MenuButton(title: "空间时间线", symbol: "chart.bar.xaxis") {
                    show(.timeline)
                    if model.tree == nil { model.scan(AppModel.homePath) }
                }
            }

            Divider()

            HStack {
                SettingsLink { Text("设置…") }
                    .buttonStyle(.link)
                Spacer()
                Button("退出 DiskLens") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
        .task { await monitor.refresh() }
    }

    private func show(_ section: AppModel.Section?) {
        if let section { model.section = section }
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(hovered ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct UsageBar: View {
    let volume: VolumeInfo

    var body: some View {
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
    }
}

/// DiskLens › Settings (⌘,).
struct SettingsView: View {
    @Environment(AccessModel.self) private var access
    @AppStorage(SpaceMonitor.Keys.menuBar) private var menuBar = true
    @AppStorage(SpaceMonitor.Keys.lowSpaceAlerts) private var lowSpaceAlerts = true
    @AppStorage(SpaceMonitor.Keys.lowSpaceThreshold) private var threshold = 20
    @AppStorage(SpaceMonitor.Keys.growthAlerts) private var growthAlerts = true

    var body: some View {
        Form {
            Section("权限") {
                LabeledContent("完全磁盘访问权限") {
                    if access.isGranted {
                        Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Text("未开启").foregroundStyle(.secondary)
                            Button("开启…") { access.openSettings() }
                        }
                    }
                }
                if let agent = access.agentStatus {
                    LabeledContent("后台助手") {
                        Text(agent == .granted ? "已开启" : "未开启，受保护文件夹的变化不会被记录")
                            .foregroundStyle(agent == .granted ? Color.green : Color.secondary)
                    }
                }
            }
            .onAppear { access.refresh() }
            Section {
                Toggle("在菜单栏显示可用空间", isOn: $menuBar)
                Text("开启时，关掉主窗口后 DiskLens 继续留在菜单栏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("提醒") {
                Toggle("可用空间不足时提醒", isOn: $lowSpaceAlerts)
                Picker("低于", selection: $threshold) {
                    Text("10 GB").tag(10)
                    Text("20 GB").tag(20)
                    Text("50 GB").tag(50)
                    Text("100 GB").tag(100)
                }
                .disabled(!lowSpaceAlerts)
                Toggle("一小时内多用了 5 GB 以上时提醒", isOn: $growthAlerts)
                Text("提醒在 DiskLens 运行时（包括只在菜单栏时）发出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: lowSpaceAlerts) { if lowSpaceAlerts { SpaceMonitor.requestNotificationPermission() } }
        .onChange(of: growthAlerts) { if growthAlerts { SpaceMonitor.requestNotificationPermission() } }
    }
}
