import Accelerate
import Darwin
import Foundation
import ImageIO
import Vision

public struct SimilarPhoto: Sendable, Hashable, Identifiable {
    public let node: Int
    public let path: String
    public let modified: Date
    public let width: Int
    public let height: Int
    /// Bytes on disk.
    public let size: Int64
    /// Bytes only this file uses; see `DuplicateFile.privateSize`.
    public let privateSize: Int64

    public var id: Int { node }
    public var pixels: Int { width * height }
}

public struct SimilarPhotoGroup: Sendable, Identifiable {
    /// The path of the photo that started the group, unique per group.
    public let id: String
    /// The photo suggested to keep comes first.
    public let photos: [SimilarPhoto]

    public init(id: String, photos: [SimilarPhoto]) {
        self.id = id
        self.photos = photos
    }

    /// Space freed by deleting every photo but the first.
    public var reclaimable: Int64 { photos.dropFirst().reduce(0) { $0 + $1.privateSize } }
}

public struct SimilarPhotoProgress: Sendable {
    public let done: Int
    public let total: Int
}

/// How alike two photos must be, as a distance between Vision feature prints. Measured
/// on real photos, recompressing, resizing and brightening stay under 0.3, a 3% crop
/// under 0.4, and a 10% crop under 0.5. Unrelated photos are usually above 0.6.
public enum PhotoSimilarity: String, CaseIterable, Sendable {
    /// Recompressed or resized copies of one photo.
    case strict
    /// Also small crops and edits.
    case standard
    /// Also shots of one scene, such as a burst.
    case loose

    var maximumDistance: Float {
        switch self {
        case .strict: 0.2
        case .standard: 0.35
        case .loose: 0.5
        }
    }
}

/// What a photo looks like, remembered for the session so that a new search with a
/// different similarity reads only what changed.
public final class PhotoPrintCache: @unchecked Sendable {
    fileprivate struct Entry {
        let modified: Date
        let length: Int64
        let width: Int
        let height: Int
        let print: [Float]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    fileprivate subscript(path: String) -> Entry? {
        get { lock.withLock { entries[path] } }
        set { lock.withLock { entries[path] = newValue } }
    }
}

/// Finds photos that look alike among the files of a scan, whatever their format or size.
/// Vision turns each photo into a feature print, and every pair is compared. Each photo
/// joins the best photo it resembles, so a long run of slowly changing shots can't chain
/// unrelated photos together.
public final class SimilarPhotoFinder: @unchecked Sendable {
    public var minimumSize: Int64 = 30_000
    public var similarity = PhotoSimilarity.standard
    /// Leave out ~/Library, where images usually belong to apps.
    public var includeLibrary = false
    public let homePath: String
    private let cache: PhotoPrintCache
    private let lock = NSLock()
    private var cancelled = false

    /// Icons and small pictures look alike without being copies of anything.
    private static let minimumLongSide = 400
    private static let thumbnailSize = 360
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp",
                                                  "avif", "cr2", "cr3", "nef", "arw", "dng"]

    public init(homePath: String = UserHome.path, cache: PhotoPrintCache = PhotoPrintCache()) {
        self.homePath = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        self.cache = cache
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Groups of similar photos, those freeing the most space first.
    public func find(in tree: FileTree, progress: (@Sendable (SimilarPhotoProgress) -> Void)? = nil) throws -> [SimilarPhotoGroup] {
        let candidates = candidates(in: tree)
        let photos = try prints(of: candidates, in: tree, progress: progress)
        if isCancelled { throw ScanError.cancelled }
        return try group(photos).map { members in
            let id = members[0].path
            return SimilarPhotoGroup(id: id, photos: members.map { photo in
                SimilarPhoto(node: photo.node, path: photo.path, modified: photo.entry.modified,
                             width: photo.entry.width, height: photo.entry.height, size: tree.ownSizes[photo.node],
                             privateSize: DuplicateFinder.privateSize(of: photo.path) ?? tree.ownSizes[photo.node])
            })
        }
        .sorted { ($0.reclaimable, $0.id) > ($1.reclaimable, $1.id) }
    }

    private func candidates(in tree: FileTree) -> [Int] {
        var nodes: [Int] = []
        for node in 1..<max(tree.count, 1) where tree.kinds[node] == .file && tree.ownSizes[node] >= minimumSize {
            let name = tree.names[node]
            guard let dot = name.lastIndex(of: "."), Self.extensions.contains(name[name.index(after: dot)...].lowercased()),
                  !tree.isRemoved(node),
                  // Reading a photo that is only in iCloud would download it.
                  !tree.flags(of: node).contains(.cloudOnly),
                  DuplicateFinder.isEligible(node, in: tree, homePath: homePath, includeLibrary: includeLibrary),
                  !tree.path(of: node).hasPrefix(homePath + "/.Trash/") else { continue }
            nodes.append(node)
        }
        return nodes
    }

    fileprivate struct Photo: Sendable {
        let node: Int
        let path: String
        let entry: PhotoPrintCache.Entry
    }

    private func prints(of nodes: [Int], in tree: FileTree,
                        progress: (@Sendable (SimilarPhotoProgress) -> Void)?) throws -> [Photo] {
        let results = PhotoBox(count: nodes.count)
        DispatchQueue.concurrentPerform(iterations: nodes.count) { index in
            guard !isCancelled else { return }
            let node = nodes[index]
            let path = tree.path(of: node)
            let photo = autoreleasepool { self.entry(for: path).map { Photo(node: node, path: path, entry: $0) } }
            let done = results.set(index, photo)
            if done % 20 == 0 || done == nodes.count {
                progress?(SimilarPhotoProgress(done: done, total: nodes.count))
            }
        }
        if isCancelled { throw ScanError.cancelled }
        return results.photos
    }

    private func entry(for path: String) -> PhotoPrintCache.Entry? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if let known = cache[path], known.modified == modified, known.length == Int64(st.st_size) { return known }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) >= Self.minimumLongSide,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let print = Self.featurePrint(of: thumbnail) else { return nil }
        let entry = PhotoPrintCache.Entry(modified: modified, length: Int64(st.st_size),
                                          width: width, height: height, print: print)
        cache[path] = entry
        return entry
    }

    private static func featurePrint(of image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        // The distances in `PhotoSimilarity` hold for this revision only.
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observation = request.results?.first, observation.elementType == .float else { return nil }
        return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Takes photos best first, so a group's first photo is the one to keep and everything
    /// in the group resembles it directly.
    private func group(_ photos: [Photo]) throws -> [[Photo]] {
        let photos = photos.sorted { Self.isBetter($0, than: $1, home: homePath) }
        guard let dimensions = photos.first?.entry.print.count else { return [] }
        let usable = photos.filter { $0.entry.print.count == dimensions }
        let limit = similarity.maximumDistance * similarity.maximumDistance

        // Laid out in one block: comparing every pair is the slow part with many photos.
        var flat = [Float]()
        flat.reserveCapacity(usable.count * dimensions)
        for photo in usable { flat.append(contentsOf: photo.entry.print) }
        let block = flat

        let neighbours = NeighbourBox(count: usable.count)
        DispatchQueue.concurrentPerform(iterations: usable.count) { i in
            guard !isCancelled else { return }
            var found: [Int] = []
            block.withUnsafeBufferPointer { prints in
                let base = prints.baseAddress!
                for j in (i + 1)..<max(usable.count, i + 1) {
                    var distance: Float = 0
                    vDSP_distancesq(base + i * dimensions, 1, base + j * dimensions, 1, &distance, vDSP_Length(dimensions))
                    if distance < limit { found.append(j) }
                }
            }
            neighbours.set(i, found)
        }
        if isCancelled { throw ScanError.cancelled }

        var taken = [Bool](repeating: false, count: usable.count)
        var groups: [[Photo]] = []
        for i in usable.indices where !taken[i] {
            let members = neighbours.values[i].filter { !taken[$0] }
            guard !members.isEmpty else { continue }
            taken[i] = true
            members.forEach { taken[$0] = true }
            groups.append([usable[i]] + members.map { usable[$0] })
        }
        return groups
    }

    /// Most pixels first, then the largest file (the least compressed), then a copy
    /// outside Downloads, then the oldest.
    private static func isBetter(_ a: Photo, than b: Photo, home: String) -> Bool {
        func inDownloads(_ photo: Photo) -> Int { photo.path.hasPrefix(home + "/Downloads/") ? 1 : 0 }
        let (x, y) = (a.entry, b.entry)
        if x.width * x.height != y.width * y.height { return x.width * x.height > y.width * y.height }
        if x.length != y.length { return x.length > y.length }
        return (inDownloads(a), x.modified, a.path) < (inDownloads(b), y.modified, b.path)
    }
}

private final class PhotoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SimilarPhotoFinder.Photo?]
    private var done = 0

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    /// Stores a result and returns how many are in.
    func set(_ index: Int, _ value: SimilarPhotoFinder.Photo?) -> Int {
        lock.withLock {
            values[index] = value
            done += 1
            return done
        }
    }

    var photos: [SimilarPhotoFinder.Photo] { values.compactMap { $0 } }
}

private final class NeighbourBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [[Int]]

    init(count: Int) {
        values = Array(repeating: [], count: count)
    }

    func set(_ index: Int, _ value: [Int]) {
        lock.withLock { values[index] = value }
    }
}
