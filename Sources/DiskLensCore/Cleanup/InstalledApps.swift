import CoreServices
import Foundation

/// Bundle identifiers of the apps installed in the usual places, used to tell
/// leftover data from data that still belongs to an app.
public struct InstalledApps: Sendable {
    private let ids: Set<String>
    /// "com.google" for "com.google.Chrome": a vendor whose apps are still here.
    private let vendors: Set<String>

    public init(bundleIDs: some Sequence<String>) {
        let lowered = Set(bundleIDs.map { $0.lowercased() })
        ids = lowered
        vendors = Set(lowered.compactMap(Self.vendor(of:)))
    }

    /// Reads the bundle identifier of every app in /Applications, ~/Applications
    /// and the system app folders, two folders deep.
    public static func discover(homePath: String = NSHomeDirectory()) -> InstalledApps {
        let roots = ["/Applications", homePath + "/Applications", "/System/Applications",
                     "/System/Applications/Utilities", "/System/Library/CoreServices"]
        var found: [String] = []
        let fm = FileManager.default
        func visit(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    if let id = Bundle(path: path)?.bundleIdentifier { found.append(id) }
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        visit(path, depth: depth + 1)
                    }
                }
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return InstalledApps(bundleIDs: found)
    }

    /// Whether `id` (a folder name such as a container or cache) belongs to an
    /// installed app, one of its helpers, or a vendor that still has apps here.
    public func owns(_ id: String) -> Bool {
        let id = id.lowercased()
        if ids.contains(id) { return true }
        if ids.contains(where: { id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) { return true }
        if let vendor = Self.vendor(of: id), vendors.contains(vendor) { return true }
        return false
    }

    /// Whether LaunchServices knows an app with this identifier anywhere on disk,
    /// including apps outside the usual folders (a build in a project folder, say).
    public static func isRegistered(_ id: String) -> Bool {
        LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() != nil
    }

    /// The check DiskLens uses: in an app folder, or known to LaunchServices.
    public func isInstalled(_ id: String) -> Bool {
        owns(id) || Self.isRegistered(id)
    }

    private static func vendor(of id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }
}
