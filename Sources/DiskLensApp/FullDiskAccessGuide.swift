import AppKit
import DiskLensCore
import Observation
import SwiftUI

/// Full Disk Access for the app and its background agent, watched live while
/// the guide is open so the user never has to come back and press a button.
@MainActor @Observable
final class AccessModel {
    private(set) var status: FullDiskAccess.Status = .unknown
    /// What the background agent last reported about itself, if it runs.
    private(set) var agentStatus: FullDiskAccess.Status?
    /// Became granted while DiskLens was open: earlier scans are missing data.
    private(set) var grantedThisSession = false
    var showGuide = false {
        didSet { if showGuide { watch() } }
    }

    static let shownKey = "onboarding.fullDiskAccessShown"

    var isGranted: Bool { status == .granted }

    func refresh() {
        let previous = status
        status = FullDiskAccess.status()
        if previous == .denied && status == .granted { grantedThisSession = true }
        agentStatus = (try? ActivityStore())?.meta("agent.fullDiskAccess")
            .flatMap { FullDiskAccess.Status(rawValue: $0.value) }
    }

    /// Shows the guide once, on the first launch without access.
    func showOnFirstLaunchIfNeeded() {
        refresh()
        guard status == .denied, !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        showGuide = true
    }

    private func watch() {
        Task {
            while showGuide && !isGranted {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
            refresh()
        }
    }

    func openSettings() {
        // The macOS 13+ pane, with the older one as a fallback.
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// The step-by-step sheet for granting Full Disk Access.
struct FullDiskAccessGuide: View {
    @Environment(AccessModel.self) private var access
    @Environment(AppModel.self) private var model
    @Environment(BackgroundRecording.self) private var recording
    @Environment(\.dismiss) private var dismiss

    private let protected = ["邮件", "信息", "Safari", "其他应用的数据", "废纸篓", "通讯录与日历"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: access.isGranted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(access.isGranted ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 6) {
                    Text(access.isGranted ? "DiskLens 已经能看到整块磁盘" : "让 DiskLens 看到整块磁盘")
                        .font(.title2.weight(.semibold))
                    Text("没有“完全磁盘访问权限”时，macOS 不允许任何应用读取这些位置，扫描出的结果会偏小：")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(protected, id: \.self) { place in
                            Text(place)
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                    if let unreadable = model.tree?.stats.unreadableDirectories, unreadable > 0, !access.isGranted {
                        Text("上次扫描有 \(unreadable) 个文件夹没能读取。")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Step(number: 1, done: access.isGranted) {
                    HStack {
                        Text("打开“系统设置 › 隐私与安全性 › 完全磁盘访问权限”。")
                        Spacer()
                        Button("打开系统设置") { access.openSettings() }
                    }
                }
                Step(number: 2, done: access.isGranted) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("打开 DiskLens 旁边的开关。列表里没有 DiskLens 的话，把这个图标拖进列表，或点列表下方的“+”添加：")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            DraggableAppIcon()
                            Button("在 Finder 中显示") { access.revealApp() }
                                .buttonStyle(.link)
                        }
                    }
                }
                Step(number: 3, done: access.isGranted) {
                    HStack(spacing: 8) {
                        if access.isGranted {
                            Text("已获得完全磁盘访问权限。")
                                .foregroundStyle(.green)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("回到这里就好，DiskLens 会自动检测到。系统提示“退出并重新打开”时，选它也可以。")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

            if access.isGranted && recording.isOn && access.agentStatus == .denied {
                Label("后台记录用的助手程序还没有这个权限。如果在列表里看到“DiskLensAgent”，也把它打开，受保护文件夹的变化才能被记录。",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("DiskLens 不会上传任何文件或数据，所有分析都在这台 Mac 上完成。", systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                if access.isGranted {
                    if model.tree != nil {
                        Button("稍后") { dismiss() }
                        Button("完整重新扫描") {
                            model.fullRescan()
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .help("之前读不到的文件夹不在变更记录里，需要完整扫描一次")
                    } else {
                        Button("完成") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("以后再说") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(28)
        .frame(width: 640)
        .animation(.smooth(duration: 0.3), value: access.isGranted)
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor)
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            content
        }
    }
}

/// The app's own icon, which can be dragged into the Full Disk Access list.
private struct DraggableAppIcon: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 40, height: 40)
            Text(Bundle.main.bundleURL.lastPathComponent)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
        .help("拖到“完全磁盘访问权限”列表中")
    }
}
