import DiskLensCore
import SwiftUI

/// Files with identical contents. Each group keeps one copy; the others can
/// go to the basket together.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("duplicates.minimumSize") private var minimumSize = 1_000_000
    @AppStorage("duplicates.includeLibrary") private var includeLibrary = false
    /// The copy to keep per group, when the user picked a different one.
    @State private var keepers: [String: Int] = [:]

    private static let homeLibrary = NSHomeDirectory() + "/Library/"

    var body: some View {
        if model.isScanning || model.isUpdating {
            ContentUnavailableView("扫描完成后才能查找重复文件", systemImage: "hourglass")
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if model.isFindingDuplicates {
                    progress
                } else if let groups = model.duplicateGroups, !model.duplicatesAreStale {
                    results(visible(groups))
                } else {
                    start
                }
            }
        }
    }

    private var hasResults: Bool {
        model.duplicateGroups != nil && !model.duplicatesAreStale
    }

    /// The current conditions reach files the last search did not look at.
    private var needsNewSearch: Bool {
        guard hasResults, let searched = model.duplicatesSearch else { return false }
        return Int64(minimumSize) < searched.minimumSize || (includeLibrary && !searched.includeLibrary)
    }

    private func search() {
        keepers = [:]
        model.findDuplicates(minimumSize: Int64(minimumSize), includeLibrary: includeLibrary)
    }

    // MARK: Filter bar

    /// Always at the top. Narrowing the conditions filters the results at once;
    /// widening them needs a new search, which the bar offers.
    private var filterBar: some View {
        HStack(spacing: 14) {
            Picker("文件至少", selection: $minimumSize) {
                Text("1 MB").tag(1_000_000)
                Text("10 MB").tag(10_000_000)
                Text("100 MB").tag(100_000_000)
                Text("1 GB").tag(1_000_000_000)
            }
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("包括资源库", isOn: $includeLibrary)
                .toggleStyle(.checkbox)
                .help("资源库（~/Library）里的副本通常属于应用，删除前要格外小心")
            if needsNewSearch {
                Label("条件放宽了，需要重新查找", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if model.isFindingDuplicates {
                Button("取消") { model.cancelFindingDuplicates() }
            } else {
                Button(hasResults ? "重新查找" : "开始查找", action: search)
                    .buttonStyle(.borderedProminent)
                    .tint(needsNewSearch || !hasResults ? .accentColor : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Start and progress

    private var start: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("查找内容完全相同的文件")
                .font(.title2.weight(.semibold))
            Text(model.duplicatesAreStale
                 ? "扫描结果更新了，请重新查找。"
                 : "在上方设好条件后点“开始查找”。只比较大小相同的文件，再逐字节确认内容一致；应用包、开发依赖和隐藏文件夹里的副本不会列出。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progress: some View {
        VStack(spacing: 14) {
            if let progress = model.duplicateProgress, progress.bytesToHash > 0 {
                ProgressView(value: Double(progress.bytesHashed), total: Double(progress.bytesToHash)) {
                    Text("正在比较文件内容")
                } currentValueLabel: {
                    Text("\(ByteFormat.string(progress.bytesHashed)) / \(ByteFormat.string(progress.bytesToHash))")
                        .monospacedDigit()
                }
                .frame(maxWidth: 360)
            } else {
                ProgressView("正在找出大小相同的文件…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    /// Groups as they stand now: narrowed to the current conditions, trashed
    /// copies dropped, the chosen keeper first.
    private func visible(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        guard let tree = model.tree else { return [] }
        return Self.narrowed(groups, in: tree, minimumSize: Int64(minimumSize), includeLibrary: includeLibrary)
            .map { group in
                var files = group.files
                if let keeper = keepers[group.id], let index = files.firstIndex(where: { $0.node == keeper }) {
                    files.insert(files.remove(at: index), at: 0)
                }
                return DuplicateGroup(id: group.id, size: group.size, files: files)
            }
    }

    /// The groups that meet the current conditions, without trashed copies.
    /// The sidebar badge uses this too, so both show the same total.
    static func narrowed(_ groups: [DuplicateGroup], in tree: FileTree, minimumSize: Int64,
                         includeLibrary: Bool) -> [DuplicateGroup] {
        groups.compactMap { group in
            guard group.size >= minimumSize else { return nil }
            let files = group.files.filter {
                !tree.isRemoved($0.node) && (includeLibrary || !$0.path.hasPrefix(homeLibrary))
            }
            return files.count > 1 ? DuplicateGroup(id: group.id, size: group.size, files: files) : nil
        }
    }

    private func results(_ groups: [DuplicateGroup]) -> some View {
        let worthIt = groups.filter { !$0.isMostlyClones }
        let reclaimable = worthIt.reduce(Int64(0)) { $0 + $1.reclaimable }
        let extras = worthIt.flatMap { $0.files.dropFirst() }.filter { !model.isInBasket($0.node) }
        return List {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(groups.isEmpty ? "没有符合条件的重复文件" : "\(groups.count) 组重复文件，可释放 \(ByteFormat.string(reclaimable))")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("每组的第一份会保留；可以在组里改选要保留的那份。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    extras.forEach { model.addToBasket($0.node) }
                } label: {
                    Label("每组保留一份，其余加入收集筐", systemImage: "tray.and.arrow.down")
                }
                .disabled(extras.isEmpty)
                .help("APFS 克隆副本不包括在内：删除它们几乎不释放空间")
            }
            .padding(.vertical, 10)
            .listRowSeparator(.hidden)

            ForEach(groups) { group in
                GroupRow(group: group) { keepers[group.id] = $0 }
            }
        }
        .listStyle(.inset)
    }
}

private struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    let keep: (Int) -> Void
    @State private var expanded = false

    var body: some View {
        let name = (group.files[0].path as NSString).lastPathComponent
        let category = FileCategory.of(name: name, kind: .file)
        let extras = group.files.dropFirst().filter { !model.isInBasket($0.node) }
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                FileRow(file: file, isKept: index == 0) { keep(file.node) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .foregroundStyle(category.color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        if group.isMostlyClones {
                            Text("APFS 克隆")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                                .help("这些副本共用同一份磁盘空间，删除几乎不会释放空间")
                        }
                    }
                    Text("\(group.files.count) 份 × \(ByteFormat.string(group.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text(ByteFormat.string(group.reclaimable))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Button(extras.isEmpty ? "已在收集筐中" : "其余加入收集筐") {
                    extras.forEach { model.addToBasket($0.node) }
                }
                .disabled(extras.isEmpty)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } }
        }
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: DuplicateFile
    let isKept: Bool
    let makeKeeper: () -> Void

    var body: some View {
        let inBasket = model.isInBasket(file.node)
        HStack(spacing: 8) {
            if isKept {
                Label("保留", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(width: 64, alignment: .leading)
            } else {
                Button("保留这份", action: makeKeeper)
                    .buttonStyle(.link)
                    .font(.caption)
                    .frame(width: 64, alignment: .leading)
            }
            Text((file.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(inBasket ? 0.45 : 1)
            Spacer()
            Text(file.modified.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
            if inBasket {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 28)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.previewURL = URL(fileURLWithPath: file.path) }
        .contextMenu {
            Button("快速查看") { model.previewURL = URL(fileURLWithPath: file.path) }
            Button("在 Finder 中显示") { model.revealInFinder(file.node) }
            if !isKept && !inBasket {
                Divider()
                Button("加入收集筐") { model.addToBasket(file.node) }
                Button("保留这份", action: makeKeeper)
            }
        }
    }
}
