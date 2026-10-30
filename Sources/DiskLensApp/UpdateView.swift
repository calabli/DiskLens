import AppKit
import DiskLensCore
import SwiftUI

/// The update window: what is new, then downloading and installing it.
struct UpdateView: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(22)
        .frame(width: 520)
    }

    private var title: String {
        switch updater.state {
        case .checking: "正在检查更新…"
        case .upToDate: "DiskLens 已是最新版本"
        case let .available(update), let .downloading(update, _), let .installing(update):
            "DiskLens \(update.version) 可以更新了"
        case .failed: "更新没能完成"
        case .idle: "软件更新"
        }
    }

    private var subtitle: String {
        "你现在用的是 \(AppUpdater.versionLabel)"
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .checking, .idle:
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            buttons { Button("取消") { updater.close() }.keyboardShortcut(.cancelAction) }
        case .upToDate:
            buttons { Button("好") { updater.close() }.keyboardShortcut(.defaultAction) }
        case let .available(update):
            notes(update)
            if update.isPrerelease {
                Label("这是预览版。", systemImage: "flask")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            buttons {
                Button("跳过这个版本") { updater.skip(update) }
                Spacer()
                Button("以后再说") { updater.close() }
                    .keyboardShortcut(.cancelAction)
                Button("下载并安装") { updater.install(update) }
                    .keyboardShortcut(.defaultAction)
            }
            Text("下载后会先校验签名，再替换当前的 DiskLens 并重新打开；旧版本会移到废纸篓。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .downloading(update, fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("正在下载 \(ByteFormat.string(Int64(Double(update.archiveSize) * fraction))) / \(ByteFormat.string(update.archiveSize))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("签名校验通过，正在安装，马上会重新打开…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Text(message)
            buttons {
                Link("在 GitHub 上下载", destination: URL(string: "https://github.com/calabli/DiskLens/releases")!)
                Spacer()
                Button("关闭") { updater.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func notes(_ update: AvailableUpdate) -> some View {
        ScrollView {
            Text(attributed(update.notes))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 220)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Release notes are Markdown; headings and lists are kept as lines, emphasis and links rendered.
    private func attributed(_ markdown: String) -> AttributedString {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { Spacer(minLength: 0); content() }
    }
}

/// The standard About panel, with when this copy was built and from which commit.
@MainActor
enum AboutPanel {
    static func show() {
        var lines: [String] = []
        if let date = AppUpdater.buildDate {
            lines.append("编译时间：" + date.formatted(.dateTime.year().month().day().hour().minute().second()))
        }
        if let commit = AppUpdater.commit {
            lines.append("代码版本：" + commit)
        }
        lines.append("数据只留在你的 Mac 上。")
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: AppUpdater.versionLabel,
            // Without this the panel adds "(build)" again after the version.
            .version: "",
            .credits: credits,
        ])
    }
}
