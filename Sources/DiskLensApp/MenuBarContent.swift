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
    @Environment(RuleLibrary.self) private var rules
    @Environment(AppUpdater.self) private var updater
    @AppStorage(AppUpdater.Keys.autoCheck) private var autoCheckUpdates = true
    @AppStorage(AppUpdater.Keys.includePrereleases) private var includePrereleases = true
    @AppStorage(RuleLibrary.Keys.autoUpdate) private var autoUpdateRules = true
    @AppStorage(SpaceMonitor.Keys.menuBar) private var menuBar = true
    @AppStorage(SpaceMonitor.Keys.menuBarShowsSpace) private var menuBarShowsSpace = false
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
                Toggle("在菜单栏显示 DiskLens", isOn: $menuBar)
                Toggle("在图标旁显示可用空间", isOn: $menuBarShowsSpace)
                    .disabled(!menuBar)
                Text("关掉时菜单栏只有一个图标，点开才看到可用空间；空间不足时会自动显示数字。开启菜单栏后，关掉主窗口 DiskLens 也会留在菜单栏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("软件更新") {
                LabeledContent("当前版本") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(AppUpdater.versionLabel)
                        if let date = AppUpdater.buildDate {
                            Text("编译于 " + date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("自动检查更新", isOn: $autoCheckUpdates)
                Toggle("包括预览版", isOn: $includePrereleases)
                HStack {
                    Text(updater.lastCheck.map { "上次检查：" + $0.formatted(.relative(presentation: .named)) } ?? "还没有检查过")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("检查更新…") { updater.check(userInitiated: true) }
                }
                Text("每天最多查一次 GitHub 上的发布列表，不发送任何关于这台 Mac 的信息。新版本下载后会先校验签名再安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("清理规则") {
                LabeledContent("当前版本") {
                    Text(rules.set.map { "第 \($0.version) 版 · \($0.rules.count) 条规则" } ?? "没能加载")
                }
                Toggle("自动更新清理规则", isOn: $autoUpdateRules)
                HStack {
                    Text(ruleStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即检查") { rules.check() }
                        .disabled(rules.status == .checking)
                }
                Text("每天最多检查一次，只下载公开的规则文件，不发送任何关于这台 Mac 的信息。规则带有签名，被改动过的不会采用。")
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
        .frame(width: 440)
        .onChange(of: lowSpaceAlerts) { if lowSpaceAlerts { SpaceMonitor.requestNotificationPermission() } }
        .onChange(of: growthAlerts) { if growthAlerts { SpaceMonitor.requestNotificationPermission() } }
    }
}

private extension SettingsView {
    var ruleStatus: String {
        switch rules.status {
        case .checking: return "正在检查…"
        case let .updated(version): return "已更新到第 \(version) 版"
        case .upToDate: return "已是最新"
        case let .failed(reason): return reason
        case .idle:
            guard let last = rules.lastCheck else { return "还没有检查过" }
            return "上次检查：" + last.formatted(.relative(presentation: .named))
        }
    }
}
