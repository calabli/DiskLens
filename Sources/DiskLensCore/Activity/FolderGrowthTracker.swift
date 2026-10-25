import CoreServices
import Darwin
import Foundation

/// Measures how much space each changed folder gained or lost, from a live
/// FSEvents stream: when a folder changes, it re-reads just that folder (one
/// level) and compares the size of the files directly inside with last time.
///
/// A folder seen for the first time has no earlier size; then files changed
/// since the last report count as new, which slightly overcounts files that
/// were only modified, but catches the common case of new downloads and caches.
public final class FolderGrowthTracker: @unchecked Sendable {
    public typealias Change = (folder: String, owner: String, bytes: Int64)

    private let root: String
    private let excluded: [String]
    private let queue: DispatchQueue
    private let reader = DirectoryReader()
    private var stream: FSEventStreamRef?
    // Touched only on `queue`.
    private var directSizes: [String: Int64] = [:]
    private var pending: [String: Int64] = [:]
    private var lastReport = Int64(Date().timeIntervalSince1970)
    private var entries: [RawEntry] = []
    private var names: [UInt8] = []

    /// - Parameters:
    ///   - excluded: folders to ignore, such as DiskLens's own database folder.
    public init(root: String, excluding excluded: [String] = [], queue: DispatchQueue) {
        self.root = root
        self.excluded = excluded
        self.queue = queue
    }

    /// Starts listening; folder changes are handled on `queue`. A long latency lets
    /// FSEvents fold the many changes of busy folders (logs, caches) into one report,
    /// and each report re-reads the folder's current state, so nothing is lost.
    public func start(latency: TimeInterval = 30) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let tracker = Unmanaged<FolderGrowthTracker>.fromOpaque(info!).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            tracker.folderChanged((0..<count).map { String(cString: cPaths[$0]) })
        }
        stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Growth per folder since the previous call. Call on `queue`.
    public func takeChanges() -> [Change] {
        let changes = pending.map { (folder: $0.key, owner: FolderOwner.owner(of: $0.key, home: root), bytes: $0.value) }
        pending = [:]
        lastReport = Int64(Date().timeIntervalSince1970)
        return changes
    }

    /// Re-measures `folders`. Called by the stream on `queue`; tests call it directly.
    func folderChanged(_ folders: [String]) {
        let unique = Set(folders.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        for folder in unique {
            guard folder == root || folder.hasPrefix(root + "/"),
                  !excluded.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") })
            else { continue }
            guard let size = directFileSize(of: folder) else {
                // Gone: whatever we knew of is gone with it.
                if let old = directSizes.removeValue(forKey: folder) { pending[folder, default: 0] -= old }
                continue
            }
            let old = directSizes[folder] ?? size.unchangedSinceLastReport
            directSizes[folder] = size.total
            if size.total != old { pending[folder, default: 0] += size.total - old }
        }
    }

    /// Size of the files directly in `folder`, and of those not touched since the last report.
    private func directFileSize(of folder: String) -> (total: Int64, unchangedSinceLastReport: Int64)? {
        let fd = open(folder, DirectoryReader.openFlags)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        entries.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
        guard reader.read(directory: fd, into: &entries, names: &names) == 0 else { return nil }
        var total: Int64 = 0
        var unchanged: Int64 = 0
        for entry in entries where entry.kind != .directory {
            total += entry.allocSize
            if entry.modTime < lastReport { unchanged += entry.allocSize }
        }
        return (total, unchanged)
    }

    /// The minute that started at or before `date`.
    public static func minute(of date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970) / 60 * 60
    }
}
