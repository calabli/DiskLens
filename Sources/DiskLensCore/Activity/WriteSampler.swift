import Darwin
import Foundation

/// Measures how many bytes each app writes to disk, from the per-process
/// counters the kernel keeps (`proc_pid_rusage`). Only processes of the
/// current user can be read; system daemons stay invisible without root.
public final class WriteSampler {
    private struct Seen {
        let startTime: UInt64
        var written: UInt64
        var app: String?
    }

    private var seen: [pid_t: Seen] = [:]
    private var lastSample = mach_absolute_time()
    private var appNames: [String: String] = [:]

    public init() {}

    /// Bytes written per app since the previous call. The first call only
    /// takes a baseline (except for processes that started after the sampler).
    public func sample() -> [String: Int64] {
        let now = mach_absolute_time()
        var totals: [String: Int64] = [:]
        var alive: [pid_t: Seen] = [:]
        for pid in Self.allPIDs() where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { continue }
            let written = info.ri_diskio_byteswritten
            let previous = seen[pid].flatMap { $0.startTime == info.ri_proc_start_abstime ? $0.written : nil }
                // A process we have not seen: count everything if it started since the last sample.
                ?? (info.ri_proc_start_abstime > lastSample ? 0 : written)
            // Look up which app a process belongs to only once, and only when it writes.
            var entry = seen[pid].flatMap { $0.startTime == info.ri_proc_start_abstime ? $0 : nil }
                ?? Seen(startTime: info.ri_proc_start_abstime, written: written, app: nil)
            entry.written = written
            if written > previous {
                if entry.app == nil { entry.app = appName(for: pid) }
                if let app = entry.app { totals[app, default: 0] += Int64(written - previous) }
            }
            alive[pid] = entry
        }
        seen = alive
        lastSample = now
        return totals
    }

    /// The app a process belongs to: the outermost .app bundle in its executable
    /// path (so helpers count toward their app), else the process name.
    private func appName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if let cached = appNames[path] { return cached }
        let name = Self.owner(ofExecutable: path)
        appNames[path] = name
        return name
    }

    /// "Google Chrome" for ".../Google Chrome.app/Contents/Frameworks/.../Helper.app/...",
    /// "node" for "/opt/homebrew/bin/node".
    static func owner(ofExecutable path: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return String(parts.last ?? Substring(path))
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0))))
    }
}

/// Who a folder's data belongs to, judged from where it is.
public enum FolderOwner {
    private static let dependencyNames: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", "Pods", ".venv", "venv", ".gradle", ".build",
    ]

    /// For a folder inside `home`: the app or place it belongs to, e.g.
    /// "com.tencent.xinWeChat", "Google", "Xcode", "下载" or "~/Movies".
    public static func owner(of path: String, home: String) -> String {
        guard path.hasPrefix(home + "/") else { return path == home ? "主目录" : "其他位置" }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first else { return "主目录" }

        if first == "Library", parts.count >= 2 {
            let area = parts[1]
            let item = parts.count >= 3 ? parts[2] : nil
            switch area {
            case "Containers", "Application Support", "Caches", "Logs", "HTTPStorages", "WebKit",
                 "Saved Application State":
                if let item {
                    return CleanupAdvisor.bundleID(fromFolderName: item) ?? item
                }
            case "Group Containers":
                if let item {
                    return CleanupAdvisor.bundleID(fromFolderName: item) ?? item
                }
            case "Developer":
                return "Xcode"
            case "Mail", "Messages", "Photos", "Safari":
                return area
            case "Mobile Documents", "CloudStorage":
                return "iCloud 云盘"
            default:
                break
            }
            return "资源库/" + area
        }
        // Dependency folders in projects, wherever they are. Generic names such as
        // "build" or "target" are not enough on their own.
        if parts.contains(where: { dependencyNames.contains($0) }) { return "开发项目依赖" }
        switch first {
        case "Downloads": return "下载"
        case "Desktop": return "桌面"
        case "Documents": return "文稿"
        case "Movies": return "影片"
        case "Pictures": return "图片"
        case "Music": return "音乐"
        case ".Trash": return "废纸篓"
        default: return "~/" + first
        }
    }
}
