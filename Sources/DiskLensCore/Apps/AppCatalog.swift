import Foundation
import Security

/// An app installed on this Mac, with what is needed to find its data.
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String?
    /// The developer's team identifier from the code signature, e.g. "UBF8T346G9".
    public let teamID: String?
    /// Identifiers of helpers inside the bundle (login items, XPC services, extensions).
    public let helperIDs: [String]
    public let executableName: String?
    /// On the read-only system volume (Safari and other built-in apps): cannot be removed.
    public let isSystemApp: Bool

    public var id: String { path }
    /// Every identifier the app's data can be filed under.
    public var allIDs: [String] { [bundleID] + helperIDs }
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }

    /// Reads the app bundle at `path`; nil if it is not one.
    public init?(path: String) {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        self.path = path
        bundleID = id
        name = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        version = info["CFBundleShortVersionString"] as? String
        executableName = info["CFBundleExecutable"] as? String
        teamID = Self.teamID(of: path)
        helperIDs = Self.helperIDs(in: path).filter { $0 != id }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey])
        isSystemApp = values?.volumeIsReadOnly ?? false
    }

    private static func teamID(of path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess, let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Bundles nested where helpers live, two levels deep at most.
    private static func helperIDs(in path: String) -> [String] {
        let places = ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/XPCServices",
                      "Contents/PlugIns", "Contents/Helpers", "Contents/Library/SystemExtensions",
                      "Contents/Frameworks"]
        var ids = Set<String>()
        let fm = FileManager.default
        for place in places {
            let folder = path + "/" + place
            guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for item in items where [".app", ".xpc", ".appex", ".systemextension"].contains(where: item.hasSuffix) {
                if let id = Bundle(path: folder + "/" + item)?.bundleIdentifier { ids.insert(id) }
            }
        }
        return ids.sorted()
    }
}

/// The apps installed in the usual places.
public enum AppCatalog {
    public static func installedApps(homePath: String = NSHomeDirectory()) -> [InstalledApp] {
        let roots = ["/Applications", homePath + "/Applications"]
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func visit(_ folder: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    if let app = InstalledApp(path: path), seen.insert(app.bundleID).inserted { apps.append(app) }
                } else if depth < 2 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: depth + 1) }
                }
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
