import AppKit
import DiskLensCore
import SwiftUI

/// Photos that look alike. Unlike exact duplicates these can differ in ways that matter,
/// so nothing is removed in bulk: the user looks at each group and decides.
struct SimilarPhotosView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("similarPhotos.similarity") private var similarity = PhotoSimilarity.standard.rawValue
    /// The photo to keep per group, when the user picked a different one.
    @State private var keepers: [String: Int] = [:]

    var body: some View {
        if model.isScanning || model.isUpdating {
            ContentUnavailableView("扫描完成后才能查找相似照片", systemImage: "hourglass")
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if model.isFindingSimilarPhotos {
                    progress
                } else if let groups = model.similarPhotoGroups, !model.similarPhotosAreStale {
                    results(visible(groups))
                } else {
                    start
                }
            }
        }
    }

    private var hasResults: Bool {
        model.similarPhotoGroups != nil && !model.similarPhotosAreStale
    }

    private func search() {
        keepers = [:]
        model.findSimilarPhotos(similarity: PhotoSimilarity(rawValue: similarity) ?? .standard)
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            Picker("相似程度", selection: $similarity) {
                Text("几乎相同").tag(PhotoSimilarity.strict.rawValue)
                Text("标准").tag(PhotoSimilarity.standard.rawValue)
                Text("同一场景").tag(PhotoSimilarity.loose.rawValue)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("“几乎相同”只找压缩或缩放过的副本；“同一场景”还会找连拍和相近的镜头")
            .onChange(of: similarity) { if hasResults { search() } }
            Spacer()
            if model.isFindingSimilarPhotos {
                Button("取消") { model.cancelFindingSimilarPhotos() }
            } else {
                Button(hasResults ? L("重新查找") : L("开始查找"), action: search)
                    .buttonStyle(.borderedProminent)
                    .tint(hasResults ? .secondary : .accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var start: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("查找看起来相似的照片")
                .font(.title2.weight(.semibold))
            Text(model.similarPhotosAreStale
                 ? "扫描结果更新了，请重新查找。"
                 : "能找出压缩过、改过尺寸或连拍的照片，分析都在这台 Mac 上完成。不包括“照片”图库、只在 iCloud 的照片和应用自带的图片。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progress: some View {
        VStack(spacing: 14) {
            if let progress = model.similarPhotoProgress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text("正在分析照片")
                } currentValueLabel: {
                    Text("\(progress.done.formatted()) / \(progress.total.formatted())")
                        .monospacedDigit()
                }
                .frame(maxWidth: 360)
            } else {
                ProgressView("正在找出照片…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Groups without trashed photos. The sidebar badge uses this too.
    static func remaining(_ groups: [SimilarPhotoGroup], in tree: FileTree) -> [SimilarPhotoGroup] {
        groups.compactMap { group in
            let photos = group.photos.filter { !tree.isRemoved($0.node) }
            return photos.count > 1 ? SimilarPhotoGroup(id: group.id, photos: photos) : nil
        }
    }

    /// Groups as they stand now, the chosen keeper first.
    private func visible(_ groups: [SimilarPhotoGroup]) -> [SimilarPhotoGroup] {
        guard let tree = model.tree else { return [] }
        return Self.remaining(groups, in: tree).map { group in
            var photos = group.photos
            if let keeper = keepers[group.id], let index = photos.firstIndex(where: { $0.node == keeper }) {
                photos.insert(photos.remove(at: index), at: 0)
            }
            return SimilarPhotoGroup(id: group.id, photos: photos)
        }
    }

    private func results(_ groups: [SimilarPhotoGroup]) -> some View {
        let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(groups.isEmpty ? L("没有找到相似的照片") : L("\(groups.count) 组相似照片，最多可释放 \(ByteFormat.string(reclaimable))"))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if !groups.isEmpty {
                        Text("相似不等于相同，请逐组确认。绿色标记的照片会保留，点其他照片可以改选，双击可以放大查看。")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    PhotoGroupRow(group: group) { keepers[group.id] = $0 }
                }
            }
            .padding(16)
        }
    }
}

private struct PhotoGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: SimilarPhotoGroup
    let keep: (Int) -> Void

    var body: some View {
        let extras = group.photos.dropFirst().filter { !model.isInBasket($0.node) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.photos.count) 张，可释放 \(ByteFormat.string(group.reclaimable))")
                    .fontWeight(.medium)
                    .monospacedDigit()
                Spacer()
                Button(extras.isEmpty ? L("已在收集筐中") : L("其余加入收集筐")) {
                    extras.forEach { model.addToBasket($0.node) }
                }
                .disabled(extras.isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(Array(group.photos.enumerated()), id: \.element.id) { index, photo in
                        PhotoCard(photo: photo, isKept: index == 0) { keep(photo.node) }
                    }
                }
            }
        }
    }
}

private struct PhotoCard: View {
    @Environment(AppModel.self) private var model
    let photo: SimilarPhoto
    let isKept: Bool
    let makeKeeper: () -> Void

    private static let side: CGFloat = 170

    var body: some View {
        let inBasket = model.isInBasket(photo.node)
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                PhotoThumbnail(path: photo.path, side: Self.side)
                    .opacity(inBasket ? 0.4 : 1)
                if isKept {
                    Label("保留", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green, in: Capsule())
                        .padding(6)
                } else if inBasket {
                    Image(systemName: "tray.full")
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isKept ? Color.green : Color.primary.opacity(0.1), lineWidth: isKept ? 2 : 1)
            }
            Text((photo.path as NSString).lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(photo.width) × \(photo.height) · \(ByteFormat.string(photo.size))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(photo.modified.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.side)
        .contentShape(Rectangle())
        .help(photo.path.abbreviatingHome)
        .onTapGesture(count: 2) { model.previewURL = URL(fileURLWithPath: photo.path) }
        .onTapGesture { if !isKept && !inBasket { makeKeeper() } }
        .contextMenu {
            Button("快速查看") { model.previewURL = URL(fileURLWithPath: photo.path) }
            Button("在 Finder 中显示") { model.revealInFinder(photo.node) }
            if !isKept && !inBasket {
                Divider()
                Button("保留这张", action: makeKeeper)
                Button("加入收集筐") { model.addToBasket(photo.node) }
            }
        }
    }
}

private struct PhotoThumbnail: View {
    let path: String
    let side: CGFloat
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) {
            let pixels = Int(side * scale)
            let path = path
            let thumbnail = await Task.detached(priority: .utility) { Self.load(path, pixels: pixels) }.value
            image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private nonisolated static func load(_ path: String, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }
}
