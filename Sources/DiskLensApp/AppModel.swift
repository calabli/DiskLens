import AppKit
import DiskLensCore
import Observation
import SwiftUI

/// One row of the folder list: a child of the folder being viewed.
struct FolderRow: Identifiable, Sendable {
    let id: Int
    let name: String
    let size: Int64
    /// Share of the folder being viewed, 0...1.
    let share: Double
    /// Size relative to the largest sibling, 0...1, for the size bar.
    let relative: Double
    let files: Int32
    let modified: Date
    let isDirectory: Bool
    let category: FileCategory
}

/// Space on the volume being scanned, as Finder reports it.
struct VolumeInfo: Equatable {
    let name: String
    let total: Int64
    /// Free right now.
    let available: Int64
    /// Free once macOS clears purgeable data (caches, local snapshots, iCloud copies).
    let availableForImportantUsage: Int64

    var purgeable: Int64 { max(availableForImportantUsage - available, 0) }
    var used: Int64 { max(total - availableForImportantUsage, 0) }

    init?(path: String) {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        name = values.volumeLocalizedName ?? "磁盘"
        self.total = Int64(total)
        self.available = Int64(available)
        availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
    }
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning(path: String, files: Int)
        case ready
        case failed(String)
    }

    static let homePath = NSHomeDirectory()
    /// The data volume holds everything users and apps write; scanning "/" would stop at its firmlinks.
    static let wholeDiskPath = "/System/Volumes/Data"

    private(set) var phase: Phase = .idle
    private(set) var tree: FileTree?
    /// The folder whose contents the list and treemap show.
    private(set) var current = 0
    /// A child of `current`, shared by the list and the treemap.
    var selection: Int?
    var sortOrder = [KeyPathComparator(\FolderRow.size, order: .reverse)] {
        didSet { refreshRows() }
    }
    private(set) var rows: [FolderRow] = []
    private(set) var basket: [Int] = []
    private(set) var volume: VolumeInfo?
    /// Bumped whenever the tree changes in place, so views redo their layout.
    private(set) var treeVersion = 0
    var previewURL: URL?
    var alertMessage: String?

    enum Section: Hashable {
        case overview
        case cleanup
    }

    var section: Section = .overview
    private(set) var suggestions: [CleanupSuggestion] = []
    private(set) var isAnalyzing = false
    private(set) var runningAppIDs: Set<String> = []
    @ObservationIgnored private var installedApps: InstalledApps?
    @ObservationIgnored private var appNames: [String: String] = [:]
    static let rules = Result { try CleanupRuleSet.bundled().rules }

    private var scanner: DiskScanner?
    private var snapshotTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var lastScanPath: String?

    // MARK: Scanning

    func scan(_ path: String) {
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        lastScanPath = path
        phase = .scanning(path: path, files: 0)
        tree = nil
        current = 0
        selection = nil
        basket = []
        rows = []
        suggestions = []
        volume = VolumeInfo(path: path)

        let scanner = DiskScanner { [weak self] files in
            Task { @MainActor in self?.reportProgress(files, path: path, generation: generation) }
        }
        self.scanner = scanner
        Task.detached(priority: .userInitiated) {
            let result = Result { try scanner.scan(path) }
            await self.finishScan(result, generation: generation)
        }
        snapshotTask = Task { [weak self] in
            await self?.followSnapshots(of: scanner, generation: generation)
        }
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    /// Shows the tree as it grows. Each snapshot rolls up and sorts the whole
    /// tree, so the pause between them scales with how long the last one took.
    private func followSnapshots(of scanner: DiskScanner, generation: Int) async {
        try? await Task.sleep(for: .milliseconds(300))
        while !Task.isCancelled {
            let started = ContinuousClock.now
            let snapshot = await Task.detached(priority: .utility) { scanner.snapshot() }.value
            guard !Task.isCancelled, generation == scanGeneration, isScanning, let snapshot else { return }
            tree = snapshot
            treeVersion += 1
            refreshRows()
            let cost = ContinuousClock.now - started
            try? await Task.sleep(for: max(.milliseconds(600), cost * 3))
        }
    }

    func rescan() {
        if let lastScanPath { scan(lastScanPath) }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        scanGeneration += 1
        if isScanning {
            phase = .idle
            tree = nil
            rows = []
            basket = []
        }
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描"
        panel.message = "选择要分析的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url.path)
        }
    }

    private func reportProgress(_ files: Int, path: String, generation: Int) {
        guard generation == scanGeneration, case .scanning = phase else { return }
        phase = .scanning(path: path, files: files)
    }

    private func finishScan(_ result: Result<FileTree, Error>, generation: Int) {
        guard generation == scanGeneration else { return }
        scanner = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        switch result {
        case let .success(tree):
            // Node ids from the snapshots are still valid, so the folder being
            // viewed and the selection carry over.
            self.tree = tree
            treeVersion += 1
            phase = .ready
            refreshRows()
            refreshSuggestions()
            // The snapshots are gone; hand their freed pages back to the system now
            // instead of whenever memory gets tight.
            Task.detached(priority: .background) {
                try? await Task.sleep(for: .seconds(1))
                malloc_zone_pressure_relief(nil, 0)
            }
        case let .failure(error):
            tree = nil
            rows = []
            basket = []
            if case ScanError.cancelled = error {
                phase = .idle
            } else {
                phase = .failed(String(describing: error))
            }
        }
    }

    // MARK: Navigation

    var canGoUp: Bool { tree != nil && current != 0 }

    /// The folders from the scan root down to `current`.
    var breadcrumb: [Int] {
        guard let tree else { return [] }
        var chain: [Int] = []
        var i = current
        while i >= 0 {
            chain.append(i)
            i = i == 0 ? -1 : Int(tree.parents[i])
        }
        return chain.reversed()
    }

    func open(_ node: Int) {
        guard let tree, tree.kinds[node] == .directory, !tree.children(of: node).isEmpty else { return }
        current = node
        selection = nil
        refreshRows()
    }

    func goUp() {
        guard let tree, current != 0 else { return }
        let child = current
        current = Int(tree.parents[current])
        refreshRows()
        selection = child
    }

    func goTo(_ node: Int) {
        guard node != current else { return }
        current = node
        selection = nil
        refreshRows()
    }

    /// The child of `current` that contains `node`, if any.
    func childOfCurrent(containing node: Int) -> Int? {
        guard let tree else { return nil }
        var i = node
        while i > 0 {
            let parent = Int(tree.parents[i])
            if parent == current { return i }
            i = parent
        }
        return nil
    }

    func url(of node: Int) -> URL? {
        guard let tree else { return nil }
        return URL(fileURLWithPath: tree.path(of: node))
    }

    func revealInFinder(_ node: Int) {
        guard let url = url(of: node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ node: Int) {
        guard let tree else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tree.path(of: node), forType: .string)
    }

    func togglePreview() {
        if previewURL != nil {
            previewURL = nil
        } else if let selection {
            previewURL = url(of: selection)
        }
    }

    private func refreshRows() {
        guard let tree else {
            rows = []
            return
        }
        let total = max(Double(tree.totalSizes[current]), 1)
        let largest = max(Double(tree.children(of: current).first.map { tree.totalSizes[Int($0)] } ?? 1), 1)
        rows = tree.children(of: current).map { child in
            let c = Int(child)
            let size = tree.totalSizes[c]
            return FolderRow(id: c, name: tree.names[c], size: size,
                             share: Double(size) / total, relative: Double(size) / largest,
                             files: tree.fileCounts[c],
                             modified: Date(timeIntervalSince1970: TimeInterval(tree.modTimes[c])),
                             isDirectory: tree.kinds[c] == .directory,
                             category: FileCategory.of(name: tree.names[c], kind: tree.kinds[c]))
        }
        .sorted(using: sortOrder)
    }

    // MARK: Cleanup suggestions

    /// Re-runs the advisor on the current tree, e.g. after a scan or after trashing.
    func refreshSuggestions() {
        guard let tree, !isScanning else { return }
        let version = treeVersion
        isAnalyzing = true
        Task {
            let rules = (try? Self.rules.get()) ?? []
            let installed: InstalledApps
            if let installedApps {
                installed = installedApps
            } else {
                installed = await Task.detached(priority: .userInitiated) { InstalledApps.discover() }.value
                installedApps = installed
            }
            let result = await Task.detached(priority: .userInitiated) {
                CleanupAdvisor { installed.isInstalled($0) }.suggestions(for: tree, rules: rules)
            }.value
            guard version == treeVersion else { return }
            suggestions = result
            isAnalyzing = false
        }
    }

    func refreshRunningApps() {
        runningAppIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    /// The owning apps of `suggestion` that are open right now.
    func runningApps(for suggestion: CleanupSuggestion) -> [String] {
        suggestion.apps.filter { runningAppIDs.contains($0.lowercased()) }
    }

    func appName(_ bundleID: String) -> String {
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
        appNames[bundleID] = name
        return name
    }

    func addToBasket(_ items: [CleanupItem]) {
        items.forEach { addToBasket($0.node) }
    }

    // MARK: Basket

    var basketTotal: Int64 {
        guard let tree else { return 0 }
        return basket.reduce(0) { $0 + tree.totalSizes[$1] }
    }

    func isInBasket(_ node: Int) -> Bool {
        guard let tree else { return false }
        return basket.contains { tree.isAncestor($0, of: node) }
    }

    /// Adds `node`; an item already covered by a folder in the basket is ignored,
    /// and items inside `node` are replaced by it.
    func addToBasket(_ node: Int) {
        guard let tree, node > 0, !tree.isRemoved(node), !isInBasket(node) else { return }
        basket.removeAll { tree.isAncestor(node, of: $0) }
        basket.append(node)
    }

    func removeFromBasket(_ node: Int) {
        basket.removeAll { $0 == node }
    }

    func clearBasket() {
        basket = []
    }

    /// Moves every basket item to the Trash and takes it out of the tree.
    func trashBasket() {
        guard !isScanning, var tree else { return }
        var failures: [String] = []
        for node in basket {
            let url = URL(fileURLWithPath: tree.path(of: node))
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                tree.remove(node)
            } catch {
                failures.append("\(tree.names[node])：\(error.localizedDescription)")
            }
        }
        basket = []
        self.tree = tree
        treeVersion += 1

        // Stay inside a folder that still exists.
        while current != 0 && tree.isRemoved(current) {
            current = Int(tree.parents[current])
        }
        if let selection, tree.isRemoved(selection) { self.selection = nil }
        refreshRows()
        refreshSuggestions()
        if let path = lastScanPath { volume = VolumeInfo(path: path) }

        if !failures.isEmpty {
            alertMessage = "有 \(failures.count) 项没能移到废纸篓：\n" + failures.prefix(5).joined(separator: "\n")
        }
    }
}

#if DEBUG
extension AppModel {
    func demoZoom(into relativePath: String) async {
        while isScanning || tree == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1.5))
        guard let tree else { return }
        var node = 0
        for part in relativePath.split(separator: "/") {
            guard let next = tree.children(of: node).first(where: { tree.names[Int($0)] == part }) else { return }
            node = Int(next)
        }
        open(node)
        try? await Task.sleep(for: .seconds(4))
        goTo(0)
    }
}
#endif

/// Drag payload for a node, as plain text so it works with the standard String transfer type.
enum NodeDrag {
    static let prefix = "disklens-node:"

    static func payload(_ node: Int) -> String { prefix + String(node) }

    static func node(from payload: String) -> Int? {
        guard payload.hasPrefix(prefix) else { return nil }
        return Int(payload.dropFirst(prefix.count))
    }
}
