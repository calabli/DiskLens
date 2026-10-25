import CoreServices
import Darwin
import Foundation

/// Folders that changed under a scan root since some point in time.
public struct ChangeSet: Sendable, Equatable {
    /// Folders whose list of entries, or an entry's size, changed.
    public var folders: Set<String> = []
    /// Folders where the journal lost detail; everything under them must be rescanned.
    public var subtrees: Set<String> = []

    public init(folders: Set<String> = [], subtrees: Set<String> = []) {
        self.folders = folders
        self.subtrees = subtrees
    }

    public var isEmpty: Bool { folders.isEmpty && subtrees.isEmpty }
}

/// Reads the system's file-change journal (FSEvents), which macOS keeps for
/// every volume even while DiskLens is not running.
public enum ChangeJournal {
    /// The latest event id; take it just before scanning so nothing is missed.
    public static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Identifies the journal of the volume holding `path`. Event ids from a
    /// different journal (another volume, or one that was reset) mean nothing.
    public static func journalID(for path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The folders under `rootPath` that changed after `eventID`, or nil when the
    /// journal cannot tell (history dropped or the root itself replaced): then
    /// only a full scan is reliable. Paths use `rootPath`'s spelling.
    public static func changes(under rootPath: String, since eventID: UInt64,
                               timeout: TimeInterval = 10) -> ChangeSet? {
        // FSEvents reports real paths (/private/var for /var, no firmlinks).
        let root = rootPath.hasSuffix("/") && rootPath.count > 1 ? String(rootPath.dropLast()) : rootPath
        let realRoot = realPath(root) ?? root

        let collector = Collector()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let collector = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for i in 0..<count {
                collector.add(path: String(cString: cPaths[i]), flags: flags[i])
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [realRoot] as CFArray, eventID, 0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))
        else { return nil }
        let queue = DispatchQueue(label: "DiskLens.ChangeJournal")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let replayed = collector.historyDone.wait(timeout: .now() + timeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Make sure the callback is not running while the result is read.
        queue.sync {}

        guard replayed, !collector.mustRescanAll else { return nil }
        var changes = ChangeSet()
        func spelled(_ path: String) -> String? {
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if trimmed == realRoot { return root }
            guard trimmed.hasPrefix(realRoot == "/" ? "/" : realRoot + "/") else { return nil }
            return root + trimmed.dropFirst(realRoot == "/" ? 0 : realRoot.count)
        }
        for path in collector.folders { if let p = spelled(path) { changes.folders.insert(p) } }
        for path in collector.subtrees {
            // Detail lost above the root means the root needs a full rescan.
            if realRoot.hasPrefix(path.hasSuffix("/") ? path : path + "/") || path == realRoot { return nil }
            if let p = spelled(path) { changes.subtrees.insert(p) }
        }
        return changes
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private final class Collector: @unchecked Sendable {
    let historyDone = DispatchSemaphore(value: 0)
    // Only touched on the stream's serial queue until `historyDone` fires.
    var folders = Set<String>()
    var subtrees = Set<String>()
    var mustRescanAll = false

    func add(path: String, flags: FSEventStreamEventFlags) {
        let flag = { (mask: Int) in flags & FSEventStreamEventFlags(mask) != 0 }
        if flag(kFSEventStreamEventFlagHistoryDone) {
            historyDone.signal()
            return
        }
        if flag(kFSEventStreamEventFlagRootChanged) || flag(kFSEventStreamEventFlagEventIdsWrapped) {
            mustRescanAll = true
        } else if flag(kFSEventStreamEventFlagMustScanSubDirs) {
            subtrees.insert(path)
        } else {
            folders.insert(path)
        }
    }
}
