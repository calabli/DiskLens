import Foundation
import Testing
@testable import DiskLensCore

/// Fake apps, a fake home folder and a fake /Library in one temporary folder.
private final class Machine {
    let root: String
    var home: String { root + "/home" }
    var apps: String { root + "/Applications" }
    var systemLibrary: String { root + "/Library" }

    init() throws {
        root = NSTemporaryDirectory() + "disklens-apps-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func app(_ name: String, id: String, helpers: [(folder: String, name: String, id: String)] = []) throws -> InstalledApp {
        let path = apps + "/" + name + ".app"
        try bundle(at: path, id: id, name: name)
        for helper in helpers {
            try bundle(at: path + "/Contents/" + helper.folder + "/" + helper.name, id: helper.id, name: helper.name)
        }
        return try #require(InstalledApp(path: path))
    }

    private func bundle(at path: String, id: String, name: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name,
                                  "CFBundleShortVersionString": "1.0"]
        try info.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
    }

    func touch(_ relative: String, under base: String? = nil, bytes: Int = 1_000) throws {
        let path = (base ?? home) + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
    }

    func launchItem(_ relative: String, label: String, program: String? = nil, under base: String? = nil) throws {
        let path = (base ?? home) + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var plist: [String: Any] = ["Label": label]
        if let program { plist["ProgramArguments"] = [program] }
        try (plist as NSDictionary).write(to: URL(fileURLWithPath: path))
    }

    func finder(_ installed: [InstalledApp]) -> AppFootprintFinder {
        var finder = AppFootprintFinder(homePath: home, installed: installed)
        finder.systemLibrary = systemLibrary
        finder.includeInstallerReceipts = false
        return finder
    }
}

@Test func appsAreReadFromTheirBundles() throws {
    let machine = try Machine()
    let editor = try machine.app("Editor", id: "com.acme.Editor",
                                 helpers: [("Library/LoginItems", "EditorHelper.app", "com.acme.Editor.Helper")])
    #expect(editor.name == "Editor" && editor.version == "1.0")
    #expect(editor.helperIDs == ["com.acme.Editor.Helper"])
    #expect(!editor.isSystemApp && !editor.isApple)
}

@Test func footprintFindsCertainAndLikelyFiles() throws {
    let machine = try Machine()
    let editor = try machine.app("Editor", id: "com.acme.Editor",
                                 helpers: [("Library/LoginItems", "EditorHelper.app", "com.acme.Editor.Helper")])
    let notes = try machine.app("Notes", id: "com.other.Notes")
    let L = "Library/"
    for path in ["Containers/com.acme.Editor/Data/a", "Containers/com.acme.Editor.Helper/Data/b",
                 "Application Support/com.acme.Editor/db", "Application Support/Editor/state",
                 "Caches/com.acme.Editor.ShipIt/update.zip", "Preferences/com.acme.Editor.plist",
                 "Preferences/ByHost/com.acme.Editor.ABC-123.plist",
                 "Saved Application State/com.acme.Editor.savedState/window",
                 "Group Containers/group.com.acme.Editor/shared",
                 "Logs/DiagnosticReports/Editor-2026-10-25-101010.ips",
                 // Belongs to Notes, and to nobody:
                 "Containers/com.other.Notes/Data/x", "Caches/com.unknown.Thing/y"] {
        try machine.touch(L + path)
    }
    try machine.launchItem(L + "LaunchAgents/com.acme.Editor.updater.plist", label: "com.acme.Editor.updater")
    try machine.launchItem(L + "LaunchAgents/com.acme.keepalive.plist", label: "com.acme.keepalive")
    try machine.launchItem("LaunchDaemons/com.acme.Editor.daemon.plist", label: "com.acme.Editor.daemon",
                           under: machine.systemLibrary)

    let footprint = machine.finder([editor, notes]).footprint(of: editor)

    let byPath = Dictionary(uniqueKeysWithValues: footprint.files.map { ($0.path.replacingOccurrences(of: machine.root, with: ""), $0) })
    #expect(footprint.files.first?.kind == .app)
    let certain = ["Containers/com.acme.Editor", "Containers/com.acme.Editor.Helper", "Application Support/com.acme.Editor",
                   "Caches/com.acme.Editor.ShipIt", "Preferences/com.acme.Editor.plist",
                   "Preferences/ByHost/com.acme.Editor.ABC-123.plist", "Saved Application State/com.acme.Editor.savedState",
                   "Group Containers/group.com.acme.Editor", "Logs/DiagnosticReports/Editor-2026-10-25-101010.ips",
                   "LaunchAgents/com.acme.Editor.updater.plist"]
    for path in certain {
        #expect(byPath["/home/Library/" + path]?.confidence == .certain, "\(path)")
    }
    #expect(byPath["/home/Library/Application Support/Editor"]?.confidence == .likely)
    #expect(byPath["/home/Library/LaunchAgents/com.acme.keepalive.plist"]?.confidence == .likely)
    #expect(byPath["/home/Library/Containers/com.other.Notes"] == nil)
    #expect(byPath["/home/Library/Caches/com.unknown.Thing"] == nil)

    let daemon = try #require(byPath["/Library/LaunchDaemons/com.acme.Editor.daemon.plist"])
    #expect(daemon.requiresAdmin && daemon.kind == .systemLaunchItem)
    #expect(footprint.adminCommand?.contains("launchctl bootout system/com.acme.Editor.daemon") == true)
}

@Test func theMostSpecificAppOwnsAnIdentifier() throws {
    let machine = try Machine()
    let chrome = try machine.app("Google Chrome", id: "com.google.Chrome")
    let canary = try machine.app("Google Chrome Canary", id: "com.google.Chrome.canary")
    try machine.touch("Library/Caches/com.google.Chrome/a")
    try machine.touch("Library/Caches/com.google.Chrome.canary/b")
    try machine.touch("Library/Application Support/Google/Chrome/Default/History")
    try machine.launchItem("Library/LaunchAgents/com.google.keystone.agent.plist", label: "com.google.keystone.agent")

    let finder = machine.finder([chrome, canary])
    let chromePaths = finder.footprint(of: chrome).files.map { ($0.path as NSString).lastPathComponent }
    let canaryPaths = finder.footprint(of: canary).files.map { ($0.path as NSString).lastPathComponent }

    #expect(chromePaths.contains("com.google.Chrome") && !chromePaths.contains("com.google.Chrome.canary"))
    #expect(chromePaths.contains("Chrome"))  // Application Support/Google/Chrome
    #expect(canaryPaths.contains("com.google.Chrome.canary"))
    // Google's updater is shared while both apps are installed.
    #expect(!chromePaths.contains("com.google.keystone.agent.plist"))
}

@Test func appBundleProgramsClaimTheirLaunchAgents() throws {
    let machine = try Machine()
    let tool = try machine.app("Tool", id: "io.maker.Tool")
    try machine.launchItem("Library/LaunchAgents/whatever.plist", label: "x.y.z",
                           program: tool.path + "/Contents/MacOS/agent")

    let files = machine.finder([tool]).footprint(of: tool).files
    #expect(files.contains { $0.path.hasSuffix("whatever.plist") && $0.confidence == .certain })
}
