import Darwin
import Foundation

/// A file or folder that belongs to an app, found by `AppFootprintFinder`.
public struct AppFile: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case app, container, groupContainer, support, caches, preferences, savedState, webData, logs
        case crashReports, scripts, launchAgent, systemLaunchItem, privilegedHelper, installedFiles
    }

    public enum Confidence: Int, Sendable, Comparable {
        /// Named after the app's identifier (or a helper's), or inside its bundle.
        case certain
        /// Named after the app or its vendor; worth a look before removing.
        case likely

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public let path: String
    public let size: Int64
    public let kind: Kind
    public let confidence: Confidence
    /// Outside the user's own folders: removing it needs an administrator (see `adminCommand`).
    public let requiresAdmin: Bool
    /// Why it is thought to belong to the app.
    public let reason: String

    public var id: String { path }
}

public struct AppFootprint: Sendable {
    public let app: InstalledApp
    /// The app bundle first, then the largest.
    public let files: [AppFile]

    public init(app: InstalledApp, files: [AppFile]) {
        self.app = app
        self.files = files
    }

    public var dataSize: Int64 { files.filter { $0.kind != .app }.reduce(0) { $0 + $1.size } }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Terminal commands for the parts only an administrator can remove.
    public var adminCommand: String? {
        let lines = files.filter(\.requiresAdmin).map { file -> String in
            switch file.kind {
            case .systemLaunchItem:
                let label = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
                let domain = file.path.contains("/LaunchDaemons/") ? "system" : "gui/$(id -u)"
                return "sudo launchctl bootout \(domain)/\(label) 2>/dev/null; sudo rm -f '\(file.path)'"
            case .installedFiles where file.path.hasPrefix("pkg:"):
                return "sudo pkgutil --forget \(file.path.dropFirst(4))"
            default:
                return "sudo rm -rf '\(file.path)'"
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Finds the data an app leaves in the system: containers, support files,
/// caches, preferences, launch agents, installer receipts.
///
/// Identifiers decide: a name that is one of the app's identifiers (or starts
/// with one and a dot) is certain. Names only matching the app's name or vendor
/// are "likely", and are left out entirely when another installed app of the
/// same vendor could be using them.
public struct AppFootprintFinder: Sendable {
    public let homePath: String
    /// Every installed app, including the one being looked at.
    public let installed: [InstalledApp]
    /// Size of a path in bytes; defaults to measuring the disk.
    public var sizeOf: @Sendable (String) -> Int64 = AppFootprintFinder.measure
    /// Where to look outside the home folder; tests point this elsewhere.
    public var systemLibrary = "/Library"
    public var includeInstallerReceipts = true

    public init(homePath: String = NSHomeDirectory(), installed: [InstalledApp]) {
        self.homePath = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        self.installed = installed
    }

    public func footprint(of app: InstalledApp) -> AppFootprint {
        var files: [AppFile] = [AppFile(path: app.path, size: sizeOf(app.path), kind: .app, confidence: .certain,
                                        requiresAdmin: false, reason: "应用本身")]
        var seen = Set([app.path])
        func add(_ path: String, _ kind: AppFile.Kind, _ confidence: AppFile.Confidence, _ reason: String, admin: Bool = false) {
            guard seen.insert(path).inserted else { return }
            files.append(AppFile(path: path, size: sizeOf(path), kind: kind, confidence: confidence,
                                 requiresAdmin: admin, reason: reason))
        }

        let library = homePath + "/Library"
        let byID: [(String, AppFile.Kind)] = [
            ("Containers", .container), ("Application Support", .support), ("Caches", .caches),
            ("Preferences", .preferences), ("Preferences/ByHost", .preferences),
            ("Saved Application State", .savedState), ("HTTPStorages", .webData), ("WebKit", .webData),
            ("Cookies", .webData), ("Logs", .logs), ("Application Scripts", .scripts),
        ]
        for (folder, kind) in byID {
            for name in Self.list(library + "/" + folder) {
                if matchesID(name, of: app) {
                    add(library + "/" + folder + "/" + name, kind, .certain, "名称与应用标识一致")
                } else if [.support, .caches, .logs].contains(kind), matchesName(name, of: app) {
                    add(library + "/" + folder + "/" + name, kind, .likely, "名称与应用名称一致")
                }
            }
        }

        // Vendor folder, then app folder: Application Support/Google/Chrome.
        for folder in ["Application Support", "Caches"] {
            for vendor in Self.list(library + "/" + folder) where vendorNames(of: app).contains(vendor.lowercased()) {
                for name in Self.list(library + "/" + folder + "/" + vendor) where shortNames(of: app).contains(name.lowercased()) {
                    add(library + "/" + folder + "/" + vendor + "/" + name, folder == "Caches" ? .caches : .support,
                        .likely, "开发商文件夹里以应用命名的文件夹")
                }
            }
        }

        for name in Self.list(library + "/Group Containers") {
            if let confidence = groupContainerMatch(name, of: app) {
                add(library + "/Group Containers/" + name, .groupContainer, confidence,
                    confidence == .certain ? "共享容器的标识属于这个应用" : "开发者团队相同")
            }
        }

        if let executable = app.executableName {
            for name in Self.list(library + "/Logs/DiagnosticReports")
            where name.hasPrefix(executable + "-") || name.hasPrefix(executable + "_") {
                add(library + "/Logs/DiagnosticReports/" + name, .crashReports, .certain, "这个应用的崩溃报告")
            }
        }

        for (folder, admin) in [(library + "/LaunchAgents", false), (systemLibrary + "/LaunchAgents", true),
                                (systemLibrary + "/LaunchDaemons", true)] {
            for name in Self.list(folder) where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                if let confidence = launchItemMatch(path, of: app) {
                    add(path, admin ? .systemLaunchItem : .launchAgent, confidence,
                        confidence == .certain ? "随应用启动的后台程序" : "同一开发商的后台程序", admin: admin)
                }
            }
        }
        for name in Self.list(systemLibrary + "/PrivilegedHelperTools") where matchesID(name, of: app) {
            add(systemLibrary + "/PrivilegedHelperTools/" + name, .privilegedHelper, .certain, "以管理员身份运行的辅助程序", admin: true)
        }

        if includeInstallerReceipts {
            for receipt in installerReceipts(of: app) { add(receipt.path, .installedFiles, receipt.confidence, receipt.reason, admin: true) }
        }

        let bundle = files[0]
        let rest = files.dropFirst().sorted { ($0.confidence, -$0.size) < ($1.confidence, -$1.size) }
        return AppFootprint(app: app, files: [bundle] + rest)
    }

    // MARK: Matching

    /// The installed app whose identifier best explains `name`: the longest identifier
    /// that equals it or prefixes it followed by a dot. Decides between e.g.
    /// com.google.Chrome and com.google.Chrome.canary.
    private func owner(of name: String) -> InstalledApp? {
        let candidate = Self.stripped(name).lowercased()
        var best: (app: InstalledApp, length: Int)?
        for app in installed {
            for id in app.allIDs {
                let id = id.lowercased()
                guard candidate == id || candidate.hasPrefix(id + ".") else { continue }
                if id.count > best?.length ?? 0 { best = (app, id.count) }
            }
        }
        return best?.app
    }

    func matchesID(_ name: String, of app: InstalledApp) -> Bool {
        owner(of: name)?.bundleID == app.bundleID
    }

    private func matchesName(_ name: String, of app: InstalledApp) -> Bool {
        let folder = name.lowercased()
        let names = [app.name, app.executableName].compactMap { $0?.lowercased() }.filter { $0.count >= 3 }
        guard names.contains(folder) else { return false }
        // Another app with the same name (or bundle name) would make this ambiguous.
        return !installed.contains { other in
            other.bundleID != app.bundleID && [other.name, other.executableName].compactMap { $0?.lowercased() }.contains(folder)
        }
    }

    /// How a vendor names its folder: the app name's first word ("Google" of "Google Chrome")
    /// or the vendor part of the identifier ("google" of com.google.Chrome).
    private func vendorNames(of app: InstalledApp) -> Set<String> {
        var names = Set<String>()
        if let first = app.name.split(separator: " ").first, app.name.contains(" ") { names.insert(first.lowercased()) }
        let parts = app.bundleID.split(separator: ".")
        if parts.count >= 3 { names.insert(parts[1].lowercased()) }
        return names.filter { $0.count >= 3 }
    }

    /// The app's name without its vendor word ("Chrome" of "Google Chrome"), and its full name.
    private func shortNames(of app: InstalledApp) -> Set<String> {
        var names: Set<String> = [app.name.lowercased()]
        let words = app.name.split(separator: " ")
        if words.count > 1 { names.insert(words.dropFirst().joined(separator: " ").lowercased()) }
        if let last = app.bundleID.split(separator: ".").last { names.insert(last.lowercased()) }
        return names.filter { $0.count >= 3 }
    }

    private func groupContainerMatch(_ name: String, of app: InstalledApp) -> AppFile.Confidence? {
        var rest = Substring(name)
        var team: Substring?
        if let dot = rest.firstIndex(of: "."), rest.distance(from: rest.startIndex, to: dot) == 10,
           rest[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            team = rest[..<dot]
            rest = rest[rest.index(after: dot)...]
        }
        if rest.hasPrefix("group.") { rest = rest.dropFirst(6) }
        if matchesID(String(rest), of: app) { return .certain }
        // Only the developer team matches: the app's unless the team has other apps here.
        if let team, let appTeam = app.teamID, team == appTeam,
           !installed.contains(where: { $0.bundleID != app.bundleID && $0.teamID == appTeam }),
           owner(of: String(rest)) == nil {
            return .likely
        }
        return nil
    }

    private func launchItemMatch(_ path: String, of app: InstalledApp) -> AppFile.Confidence? {
        let plist = NSDictionary(contentsOfFile: path) as? [String: Any] ?? [:]
        let label = plist["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let programs = ([plist["Program"] as? String] + (plist["ProgramArguments"] as? [String] ?? []).prefix(1).map { $0 })
            .compactMap { $0 }
        if programs.contains(where: { $0.hasPrefix(app.path + "/") }) || matchesID(label, of: app) { return .certain }
        // A vendor's updater (com.google.keystone.agent for Chrome) when no other app of that vendor remains.
        let vendor = app.bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
        guard vendor.split(separator: ".").count == 2, label.lowercased().hasPrefix(vendor + "."),
              !installed.contains(where: { $0.bundleID != app.bundleID && $0.bundleID.lowercased().hasPrefix(vendor + ".") })
        else { return nil }
        return .likely
    }

    /// Installer packages registered for the app; listed by receipt, removed with `pkgutil --forget`.
    private func installerReceipts(of app: InstalledApp) -> [(path: String, confidence: AppFile.Confidence, reason: String)] {
        guard let output = Self.run("/usr/sbin/pkgutil", ["--pkgs"]) else { return [] }
        return output.split(separator: "\n").map(String.init).compactMap { pkg in
            matchesID(pkg, of: app) ? ("pkg:" + pkg, .certain, "安装包记录") : nil
        }
    }

    // MARK: Helpers

    /// "com.example.App" from "com.example.App.plist", "….savedState", "….binarycookies".
    static func stripped(_ name: String) -> String {
        var result = name
        for suffix in [".plist", ".savedState", ".binarycookies", ".sharedfilelist"] where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result
    }

    private static func list(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Allocated size: a scan for folders, the file's blocks otherwise.
    public static func measure(_ path: String) -> Int64 {
        if path.hasPrefix("pkg:") { return 0 }
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if st.st_mode & S_IFMT == S_IFDIR {
            var options = ScanOptions()
            options.threadCount = 4
            return (try? DiskScanner(options: options).scan(path).totalSize) ?? 0
        }
        return Int64(st.st_blocks) * 512
    }
}
