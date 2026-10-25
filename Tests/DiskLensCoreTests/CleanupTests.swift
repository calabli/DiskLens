import Foundation
import Testing
@testable import DiskLensCore

/// A fake home folder on disk, scanned like a real one.
private final class FakeHome {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "disklens-home-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ relative: String, bytes: Int = 4_096) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Sets the modification date of `relative` and everything inside it.
    func age(_ relative: String, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        let base = root + "/" + relative
        let fm = FileManager.default
        // Deepest first, so touching a file does not refresh its folder afterwards.
        let paths = ((fm.subpaths(atPath: base) ?? []).map { base + "/" + $0 } + [base])
            .sorted { $0.count > $1.count }
        for path in paths {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    func scan() throws -> FileTree {
        try DiskScanner().scan(root)
    }

    func advisor(installed: Set<String> = []) -> CleanupAdvisor {
        var advisor = CleanupAdvisor(homePath: root) { installed.contains($0) }
        advisor.minimumSuggestionSize = 1
        advisor.minimumProjectItemSize = 1
        advisor.minimumLeftoverItemSize = 1
        return advisor
    }
}

private func rules() throws -> [CleanupRule] {
    try CleanupRuleSet.bundled().rules
}

@Test func bundledRulesAreWellFormed() throws {
    let rules = try rules()
    #expect(rules.count >= 30)
    #expect(Set(rules.map(\.id)).count == rules.count)
    for rule in rules {
        #expect(!rule.title.isEmpty && !rule.explanation.isEmpty && !rule.consequence.isEmpty, "\(rule.id)")
        #expect(!rule.paths.isEmpty && rule.paths.allSatisfy { $0.hasPrefix("~/") }, "\(rule.id)")
        #expect((rule.action == .command) == (rule.command != nil), "\(rule.id)")
        if rule.safety == .info { #expect(rule.action == .command || rule.action == CleanupAction.none, "\(rule.id)") }
    }
}

@Test func rulesMatchWildcardPathsAndReportSizes() throws {
    let home = try FakeHome()
    try home.write("Library/Developer/Xcode/DerivedData/App-abc/Build/big.bin", bytes: 300_000)
    try home.write("Library/Developer/Xcode/DerivedData/Other-def/Index/small.bin", bytes: 50_000)
    try home.write("Downloads/Tool.dmg", bytes: 2_000_000)
    try home.write("Downloads/notes.txt")

    let suggestions = home.advisor().suggestions(for: try home.scan(), rules: try rules())

    let derived = try #require(suggestions.first { $0.id == "xcode.derived-data" })
    #expect(derived.safety == .safe && derived.regenerable)
    #expect(derived.items.map(\.label) == ["~/Library/Developer/Xcode/DerivedData/App-abc",
                                           "~/Library/Developer/Xcode/DerivedData/Other-def"])
    let installers = try #require(suggestions.first { $0.id == "downloads.installers" })
    #expect(installers.items.map(\.label) == ["~/Downloads/Tool.dmg"])
}

@Test func onlyInactiveUserProjectsHaveTheirDependenciesSuggested() throws {
    let home = try FakeHome()
    try home.write("code/old-app/package.json")
    try home.write("code/old-app/src/index.js")
    try home.write("code/old-app/node_modules/left-pad/index.js", bytes: 200_000)
    try home.write("code/old-app/node_modules/left-pad/node_modules/x/package.json")
    try home.age("code/old-app", days: 200)

    try home.write("code/new-app/package.json")
    try home.write("code/new-app/node_modules/react/index.js", bytes: 200_000)

    try home.write("code/rusty/Cargo.toml")
    try home.write("code/rusty/target/debug/app", bytes: 200_000)
    try home.age("code/rusty", days: 120)

    // Not the user's projects: a hidden tool folder and app data.
    try home.write(".npm-global/lib/node_modules/tool/package.json")
    try home.write(".npm-global/lib/node_modules/tool/node_modules/dep/index.js", bytes: 200_000)
    try home.age(".npm-global", days: 300)
    try home.write("Library/Application Support/Code/ext/package.json")
    try home.write("Library/Application Support/Code/ext/node_modules/a/index.js", bytes: 200_000)
    try home.age("Library", days: 300)

    let suggestions = home.advisor().suggestions(for: try home.scan(), rules: [])

    let projects = try #require(suggestions.first { $0.id == "heuristic.inactive-projects" })
    #expect(Set(projects.items.map(\.label)) == ["old-app/node_modules", "rusty/target"])
    let oldApp = try #require(projects.items.first { $0.label == "old-app/node_modules" })
    #expect(try #require(oldApp.lastModified) < Date().addingTimeInterval(-150 * 86_400))
}

@Test func leftoverDataIsOnlySuggestedForAppsThatAreGone() throws {
    let home = try FakeHome()
    try home.write("Library/Application Support/com.gone.Editor/data.db", bytes: 100_000)
    try home.write("Library/Caches/com.gone.Editor/cache.bin", bytes: 100_000)
    try home.write("Library/Application Support/com.still.Here/data.db", bytes: 100_000)
    try home.write("Library/Containers/com.apple.Notes/Data/x.bin", bytes: 100_000)
    try home.write("Library/Application Support/Google/Chrome/x.bin", bytes: 100_000)
    // Claimed by a rule, so not reported again as leftover data.
    try home.write("Library/Caches/com.spotify.client/Data/x.bin", bytes: 100_000)

    let suggestions = home.advisor(installed: ["com.still.Here"])
        .suggestions(for: try home.scan(), rules: try rules())

    let leftovers = try #require(suggestions.first { $0.id == "heuristic.leftover-apps" })
    #expect(Set(leftovers.items.map(\.label)) == ["com.gone.Editor · 应用数据", "com.gone.Editor · 缓存"])
    #expect(leftovers.safety == .review)
    #expect(suggestions.contains { $0.id == "spotify.cache" })
}

@Test func suggestionsAreOrderedBySafetyThenSize() throws {
    let home = try FakeHome()
    try home.write("Library/Caches/Homebrew/a.tar.gz", bytes: 100_000)
    try home.write("Library/Caches/pip/b.whl", bytes: 400_000)
    try home.write("Downloads/Big.dmg", bytes: 2_000_000)

    let ids = home.advisor().suggestions(for: try home.scan(), rules: try rules()).map(\.id)

    #expect(ids == ["pip.cache", "homebrew.cache", "downloads.installers"])
}

@Test func bundleIDsAreReadFromLibraryFolderNames() {
    #expect(CleanupAdvisor.bundleID(fromFolderName: "com.example.App") == "com.example.App")
    #expect(CleanupAdvisor.bundleID(fromFolderName: "com.example.App.savedState") == "com.example.App")
    #expect(CleanupAdvisor.bundleID(fromFolderName: "group.com.example.App") == "com.example.App")
    #expect(CleanupAdvisor.bundleID(fromFolderName: "5A4RE8SF68.com.tencent.xinWeChat.IPCHelper")
        == "com.tencent.xinWeChat.IPCHelper")
    #expect(CleanupAdvisor.bundleID(fromFolderName: "UBF8T346G9.Office") == nil)
    #expect(CleanupAdvisor.bundleID(fromFolderName: "Google") == nil)
    #expect(CleanupAdvisor.bundleID(fromFolderName: "JetBrains") == nil)
    #expect(CleanupAdvisor.bundleID(fromFolderName: "my.folder with space.x") == nil)
}

@Test func installedAppsOwnTheirHelpersAndVendorSiblings() {
    let apps = InstalledApps(bundleIDs: ["com.tencent.xinWeChat", "com.google.Chrome"])
    #expect(apps.owns("com.tencent.xinWeChat"))
    #expect(apps.owns("com.tencent.xinwechat.MiniProgram"))
    #expect(apps.owns("com.google.Keystone"))  // same vendor still installed
    #expect(!apps.owns("com.adobe.Photoshop"))
}
