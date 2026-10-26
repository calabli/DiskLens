import Foundation

/// The home folder DiskLens works with. Normally the user's own; setting
/// DISKLENS_DEMO_HOME points it, and DiskLens's own saved data, at a stand-in
/// folder of made-up files, for screenshots and demos.
public enum UserHome {
    public static let demoPath: String? = ProcessInfo.processInfo.environment["DISKLENS_DEMO_HOME"]
        .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }

    public static var path: String { demoPath ?? NSHomeDirectory() }

    /// ~/Library/Application Support or ~/Library/Caches, inside the stand-in home in a demo.
    public static func directory(_ kind: FileManager.SearchPathDirectory) -> URL {
        if let demoPath {
            let name = kind == .cachesDirectory ? "Caches" : "Application Support"
            return URL(fileURLWithPath: demoPath).appendingPathComponent("Library").appendingPathComponent(name)
        }
        return FileManager.default.urls(for: kind, in: .userDomainMask)[0]
    }
}

extension String {
    /// The path with the home folder shown as `~`.
    public var abbreviatingHome: String {
        let home = UserHome.path
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return (self as NSString).abbreviatingWithTildeInPath
    }
}
