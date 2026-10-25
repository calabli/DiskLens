import Darwin
import Foundation

/// Whether this process has Full Disk Access, which macOS requires to read
/// mail, messages, Safari data, other apps' containers and the Trash.
public enum FullDiskAccess {
    public enum Status: String, Sendable {
        case granted
        case denied
        /// None of the probe files exist, so access cannot be told.
        case unknown
    }

    /// Files and folders that only processes with Full Disk Access can open.
    static func probes(home: String) -> [String] {
        [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
        ]
    }

    /// Opening any probe proves access; a permission error on one proves its absence.
    public static func status(home: String = NSHomeDirectory()) -> Status {
        var denied = false
        for path in probes(home: home) {
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return denied ? .denied : .unknown
    }
}
