import AppKit
import DiskLensCore
import SwiftUI

extension UnreadableFolder {
    /// Why the folder could not be read, in a few words.
    var reason: String {
        switch code {
        case EPERM: "受 macOS 隐私保护"
        case EACCES: "没有读取权限"
        default: String(cString: strerror(code))
        }
    }
}

/// Every folder the scan could not open, grouped by why, with ways to find them.
struct UnreadableFoldersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AccessModel.self) private var access
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    private enum Group: CaseIterable {
        case privacy, permissions, other

        init(_ folder: UnreadableFolder) {
            self = folder.needsFullDiskAccess ? .privacy : folder.code == EACCES ? .permissions : .other
        }

        var title: String {
            switch self {
            case .privacy: "受 macOS 隐私保护"
            case .permissions: "属于系统或其他用户"
            case .other: "其他原因"
            }
        }

        var detail: String {
            switch self {
            case .privacy: "开启完全磁盘访问权限后就能读取。"
            case .permissions: "只有它们的主人或管理员能打开，DiskLens 不会绕过这些权限。"
            case .other: "读取时出了错，可能是文件夹正在变动或磁盘有问题。"
            }
        }
    }

    var body: some View {
        let unreadable = model.tree?.stats.unreadable ?? []
        let total = model.tree?.stats.unreadableDirectories ?? 0
        let groups = Dictionary(grouping: unreadable, by: Group.init)
        // Names shared by several folders (every app container has a "Data") get their parent's name too.
        let names = unreadable.map { ($0.path as NSString).lastPathComponent }
        let repeated = Set(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("读不到的文件夹")
                        .font(.title3.weight(.semibold))
                    Text("这 \(total) 个文件夹没能打开，里面占用的空间没有算进结果。")
                        .foregroundStyle(.secondary)
                }
            }

            List(selection: $selection) {
                ForEach(Group.allCases, id: \.self) { group in
                    if let folders = groups[group] {
                        Section {
                            ForEach(folders.sorted { $0.path < $1.path }, id: \.path) { folder in
                                FolderLine(folder: folder, showsParent: repeated.contains((folder.path as NSString).lastPathComponent),
                                           showsReason: group == .other)
                                    .tag(folder.path)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(group.title)（\(folders.count)）")
                                Text(group.detail).font(.caption).foregroundStyle(.secondary).textCase(nil)
                            }
                            .padding(.bottom, 2)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { paths in
                if let path = paths.first {
                    Button("在概览中定位") { locate(path) }
                    Button("在访达中显示") { showInFinder(path) }
                    Button("拷贝路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
            } primaryAction: { paths in
                if let path = paths.first { locate(path) }
            }

            if unreadable.count < total {
                Text("只列出了前 \(unreadable.count) 个。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if groups[.privacy] != nil && !access.isGranted {
                    Button("开启完全磁盘访问权限…") {
                        dismiss()
                        access.showGuide = true
                    }
                }
                Spacer()
                Button("在访达中显示") { selection.map(showInFinder) }
                    .disabled(selection == nil)
                Button("在概览中定位") { selection.map(locate) }
                    .disabled(selection == nil)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }

    private func locate(_ path: String) {
        model.reveal(path: path)
        dismiss()
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct FolderLine: View {
    let folder: UnreadableFolder
    let showsParent: Bool
    let showsReason: Bool

    var body: some View {
        let parent = (folder.path as NSString).deletingLastPathComponent
        let name = (folder.path as NSString).lastPathComponent
        let title = showsParent ? (parent as NSString).lastPathComponent + "/" + name : name
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text((parent as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if showsReason {
                Text(folder.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(folder.path)
    }
}
