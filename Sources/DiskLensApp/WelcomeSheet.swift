import AppKit
import DiskLensCore
import SwiftUI

/// Shown once, on the first launch: how DiskLens works and why it is safe to try.
struct WelcomeSheet: View {
    @Environment(AccessModel.self) private var access

    private let privacyURL = URL(string: "https://github.com/calabli/DiskLens/blob/main/PRIVACY.md")!

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 DiskLens")
                        .font(.title2.weight(.semibold))
                    Text("看清空间都去哪了，再由你决定删什么。")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                WelcomePoint(symbol: "magnifyingglass", title: L("先扫描"),
                             detail: L("扫描主目录或整个磁盘，只读取，不改动任何文件。"))
                WelcomePoint(symbol: "tray.full", title: L("放进收集筐"),
                             detail: L("看到不需要的东西就放进收集筐，确认后才会处理。"))
                WelcomePoint(symbol: "arrow.uturn.backward", title: L("可以反悔"),
                             detail: L("文件会移到废纸篓，清空之前都能放回原处。开发工具的清理命令除外，删除前会单独确认。"))
                WelcomePoint(symbol: "hand.raised", title: L("数据留在本机"),
                             detail: L("不需要账号，文件和扫描结果都不会上传。"))
            }

            HStack {
                Link("隐私说明", destination: privacyURL)
                Spacer()
                Button("开始") { access.showWelcome = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}

private struct WelcomePoint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
