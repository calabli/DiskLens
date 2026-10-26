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
    /// The scan could not list this folder, so its size is missing.
    var unreadable: UnreadableFolder?
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
    /// Bumped whenever the tree changes, so views redo their layout.
    private(set) var treeVersion = 0
    /// Bumped when a different tree replaces the current one, which renumbers
    /// nodes; trashing items changes the tree in place and keeps node ids.
    private(set) var treeGeneration = 0
    var previewURL: URL?
    var alertMessage: String?
    /// The list of folders the scan could not read is open.
    var showUnreadable = false
    @ObservationIgnored private var unreadableNodes: (version: Int, byNode: [Int: UnreadableFolder]) = (-1, [:])

    enum Section: Hashable {
        case overview
        case cleanup
        case largeFiles
        case changes
        case timeline
        case duplicates
        case storage
        case apps
    }

    var section: Section = .overview
    private(set) var suggestions: [CleanupSuggestion] = []
    private(set) var isAnalyzing = false
    private(set) var runningAppIDs: Set<String> = []
    private(set) var largeFiles: [LargeFile] = []
    /// Bringing a saved or shown result up to date from the change journal.
    private(set) var isUpdating = false
    /// When the result on screen was scanned, while it is a saved one being updated.
    private(set) var showingSavedScanFrom: Date?
    /// What changed since the previous scan of this folder.
    private(set) var comparison: ScanComparison?
    @ObservationIgnored private var baseScan: (scannedAt: Date, eventID: UInt64, journalID: String?)?
    nonisolated static let cache = ScanCache.standard
    nonisolated static let history = ScanHistory(directory: ScanCache.standard.directory)
    /// When each large file was last opened, from Spotlight; filled in after the list.
    private(set) var lastUsed: [Int: Date] = [:]
    @ObservationIgnored private var installedApps: InstalledApps?
    @ObservationIgnored private var appNames: [String: String] = [:]
    static let rules = Result { try CleanupRuleSet.bundled().rules }

    private var scanner: DiskScanner?
    private var snapshotTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var lastScanPath: String?

    // MARK: Scanning

    /// Scans `path`. A saved result of an earlier scan is shown right away and
    /// brought up to date from the change journal, unless `full` asks for a fresh scan.
    func scan(_ path: String, full: Bool = false) {
        let previous = tree.flatMap { tree in
            tree.rootPath == path ? baseScan.map { (tree, $0.scannedAt) } : nil
        }
        cancelScan()
        scanGeneration += 1
        let generation = scanGeneration
        lastScanPath = path
        resetForNewScan()
        volume = VolumeInfo(path: path)
        // Taken before reading anything, so changes made during the scan show up next time.
        let eventID = ChangeJournal.currentEventID()
        let journalID = ChangeJournal.journalID(for: path)
        phase = .scanning(path: path, files: 0)

        guard !full, FileManager.default.fileExists(atPath: Self.cache.url(forRoot: path).path) else {
            startFullScan(path, eventID: eventID, journalID: journalID, previous: previous, generation: generation)
            return
        }
        isUpdating = true
        Task {
            let saved = await Task.detached(priority: .userInitiated) { Self.cache.load(rootPath: path) }.value
            guard generation == scanGeneration else { return }
            guard let saved else {
                isUpdating = false
                startFullScan(path, eventID: eventID, journalID: journalID, previous: previous, generation: generation)
                return
            }
            tree = saved.tree
            treeVersion += 1
            treeGeneration += 1
            current = 0
            phase = .ready
            showingSavedScanFrom = saved.scannedAt
            refreshRows()
            await update(from: saved, eventID: eventID, journalID: journalID, generation: generation)
        }
    }

    /// Re-reads only what changed since the result on screen was scanned.
    func rescan() {
        guard let lastScanPath else { return }
        guard let tree, let baseScan, !isBusy else {
            scan(lastScanPath)
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        let base = CachedScan(tree: tree, scannedAt: baseScan.scannedAt, eventID: baseScan.eventID,
                              journalID: baseScan.journalID)
        isUpdating = true
        Task {
            await update(from: base, eventID: ChangeJournal.currentEventID(),
                         journalID: ChangeJournal.journalID(for: lastScanPath), generation: generation)
        }
    }

    func fullRescan() {
        if let lastScanPath { scan(lastScanPath, full: true) }
    }

    var isBusy: Bool { isScanning || isUpdating }

    private func resetForNewScan() {
        tree = nil
        current = 0
        selection = nil
        basket = []
        rows = []
        suggestions = []
        largeFiles = []
        lastUsed = [:]
        comparison = nil
        duplicateGroups = nil
        baseScan = nil
        showingSavedScanFrom = nil
        isUpdating = false
    }

    private func startFullScan(_ path: String, eventID: UInt64, journalID: String?,
                               previous: (FileTree, Date)?, generation: Int) {
        let scanner = DiskScanner { [weak self] files in
            Task { @MainActor in self?.reportProgress(files, path: path, generation: generation) }
        }
        self.scanner = scanner
        Task.detached(priority: .userInitiated) {
            let result = Result { try scanner.scan(path) }
            await self.finishScan(result, eventID: eventID, journalID: journalID, previous: previous,
                                  generation: generation)
        }
        snapshotTask = Task { [weak self] in
            await self?.followSnapshots(of: scanner, generation: generation)
        }
    }

    /// Updates `base` from the change journal (or rescans fully if the journal
    /// cannot tell), then swaps the result in and compares it with `base`.
    private func update(from base: CachedScan, eventID: UInt64, journalID: String?, generation: Int) async {
        let path = base.tree.rootPath
        let result = await Task.detached(priority: .userInitiated) { () -> Result<FileTree, Error> in
            Result {
                if base.journalID != nil, base.journalID == journalID,
                   let changes = ChangeJournal.changes(under: path, since: base.eventID) {
                    return try TreeUpdater.update(base.tree, applying: changes)
                }
                return try DiskScanner().scan(path)
            }
        }.value
        guard generation == scanGeneration else { return }
        isUpdating = false
        showingSavedScanFrom = nil
        switch result {
        case let .success(updated):
            adopt(updated)
            phase = .ready
            remember(updated, eventID: eventID, journalID: journalID)
            compare(base.tree, from: base.scannedAt, with: updated)
        case let .failure(error):
            alertMessage = "没能更新扫描结果：\(error)"
        }
    }

    /// Shows `newTree` in place of the current one, finding the folder being
    /// viewed, the selection and the basket again by path (ids change).
    private func adopt(_ newTree: FileTree) {
        let old = tree
        let currentPath = old.map { $0.path(of: current) }
        let selectionPath = selection.flatMap { node in old.map { $0.path(of: node) } }
        let basketPaths = basket.compactMap { node in old.map { $0.path(of: node) } }
        tree = newTree
        treeVersion += 1
        treeGeneration += 1
        current = currentPath.flatMap(newTree.node(atPath:)) ?? 0
        selection = selectionPath.flatMap(newTree.node(atPath:))
        basket = basketPaths.compactMap(newTree.node(atPath:))
        refreshRows()
        refreshSuggestions()
        refreshLargeFiles()
    }

    /// Saves `tree` for next time and adds it to the scan history, off the main thread.
    private func remember(_ tree: FileTree, eventID: UInt64, journalID: String?) {
        let scannedAt = Date()
        baseScan = (scannedAt, eventID, journalID)
        Task.detached(priority: .utility) {
            try? Self.cache.save(CachedScan(tree: tree, scannedAt: scannedAt, eventID: eventID, journalID: journalID))
            try? Self.history.record(tree, at: scannedAt)
        }
    }

    private func compare(_ previous: FileTree, from date: Date, with current: FileTree) {
        Task {
            let result = await Task.detached(priority: .utility) {
                ScanComparison(previous: previous, previousDate: date, current: current)
            }.value
            if self.tree?.rootPath == current.rootPath { comparison = result }
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
            treeGeneration += 1
            refreshRows()
            let cost = ContinuousClock.now - started
            try? await Task.sleep(for: max(.milliseconds(600), cost * 3))
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        scanGeneration += 1
        isUpdating = false
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

    private func finishScan(_ result: Result<FileTree, Error>, eventID: UInt64, journalID: String?,
                            previous: (FileTree, Date)?, generation: Int) {
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
            treeGeneration += 1
            phase = .ready
            refreshRows()
            refreshSuggestions()
            refreshLargeFiles()
            remember(tree, eventID: eventID, journalID: journalID)
            if let (previousTree, date) = previous { compare(previousTree, from: date, with: tree) }
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
        let unreadable = unreadableFolders(in: tree)
        rows = tree.children(of: current).map { child in
            let c = Int(child)
            let size = tree.totalSizes[c]
            return FolderRow(id: c, name: tree.names[c], size: size,
                             share: Double(size) / total, relative: Double(size) / largest,
                             files: tree.fileCounts[c],
                             modified: Date(timeIntervalSince1970: TimeInterval(tree.modTimes[c])),
                             isDirectory: tree.kinds[c] == .directory,
                             category: FileCategory.of(name: tree.names[c], kind: tree.kinds[c]),
                             unreadable: unreadable[c])
        }
        .sorted(using: sortOrder)
    }

    /// The unreadable folders of `tree` by node, worked out once per tree.
    private func unreadableFolders(in tree: FileTree) -> [Int: UnreadableFolder] {
        if unreadableNodes.version != treeVersion {
            var byNode: [Int: UnreadableFolder] = [:]
            for folder in tree.stats.unreadable {
                if let node = tree.node(atPath: folder.path) { byNode[node] = folder }
            }
            unreadableNodes = (treeVersion, byNode)
        }
        return unreadableNodes.byNode
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

    /// Lists the largest files, then looks up when each was last opened.
    func refreshLargeFiles() {
        guard let tree, !isScanning else { return }
        let version = treeVersion
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                LargeFileFinder.find(in: tree, minimumSize: 50_000_000)
            }.value
            guard version == treeVersion else { return }
            largeFiles = files
            let dates = await Task.detached(priority: .utility) {
                var dates: [Int: Date] = [:]
                for file in files {
                    if let date = LargeFileFinder.lastUsedDate(ofFileAt: tree.path(of: file.node)) {
                        dates[file.node] = date
                    }
                }
                return dates
            }.value
            guard version == treeVersion else { return }
            lastUsed = dates
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

    /// Shows the item at `path` in the overview: its folder opened, the item selected.
    func reveal(path: String) {
        guard let tree, let node = tree.node(atPath: path) else { return }
        section = .overview
        current = node == 0 ? 0 : Int(tree.parents[node])
        refreshRows()
        selection = node == 0 ? nil : node
    }

    func addToBasket(_ items: [CleanupItem]) {
        items.forEach { addToBasket($0.node) }
    }

    // MARK: Duplicates

    private(set) var duplicateGroups: [DuplicateGroup]?
    private(set) var duplicateProgress: DuplicateProgress?
    private(set) var isFindingDuplicates = false
    /// The tree generation the duplicate groups' node ids belong to.
    private(set) var duplicatesGeneration = -1
    /// The conditions the groups were found with; results can be narrowed below them, not widened.
    private(set) var duplicatesSearch: (minimumSize: Int64, includeLibrary: Bool)?
    @ObservationIgnored private var duplicateFinder: DuplicateFinder?

    var duplicatesAreStale: Bool { duplicateGroups != nil && duplicatesGeneration != treeGeneration }

    func findDuplicates(minimumSize: Int64, includeLibrary: Bool) {
        guard let tree, !isBusy else { return }
        duplicateFinder?.cancel()
        let finder = DuplicateFinder()
        finder.minimumSize = minimumSize
        finder.includeLibrary = includeLibrary
        duplicateFinder = finder
        isFindingDuplicates = true
        duplicateProgress = nil
        let generation = treeGeneration
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try finder.find(in: tree) { progress in
                        Task { @MainActor in
                            guard self.duplicateFinder === finder else { return }
                            self.duplicateProgress = progress
                        }
                    }
                }
            }.value
            guard duplicateFinder === finder else { return }
            isFindingDuplicates = false
            duplicateFinder = nil
            if case let .success(groups) = result {
                duplicateGroups = groups
                duplicatesGeneration = generation
                duplicatesSearch = (minimumSize, includeLibrary)
            }
        }
    }

    func cancelFindingDuplicates() {
        duplicateFinder?.cancel()
        duplicateFinder = nil
        isFindingDuplicates = false
    }

    // MARK: Basket

    /// A file or folder outside the scanned tree (an app in /Applications, say).
    struct ExternalItem: Identifiable, Hashable {
        let path: String
        let size: Int64
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Basket items that are not in the scanned tree.
    private(set) var externalBasket: [ExternalItem] = []

    var basketCount: Int { basket.count + externalBasket.count }
    var basketIsEmpty: Bool { basket.isEmpty && externalBasket.isEmpty }

    var basketTotal: Int64 {
        let inTree = tree.map { tree in basket.reduce(Int64(0)) { $0 + tree.totalSizes[$1] } } ?? 0
        return inTree + externalBasket.reduce(0) { $0 + $1.size }
    }

    /// Adds a path, as a node when the scan has it, else as an external item.
    func addToBasket(path: String, size: Int64) {
        if let tree, let node = tree.node(atPath: path), node > 0 {
            addToBasket(node)
            return
        }
        guard !isInBasket(path: path) else { return }
        externalBasket.removeAll { $0.path.hasPrefix(path + "/") }
        externalBasket.append(ExternalItem(path: path, size: size))
    }

    func isInBasket(path: String) -> Bool {
        if let tree, let node = tree.node(atPath: path), node > 0 { return isInBasket(node) }
        return externalBasket.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    func removeFromBasket(path: String) {
        externalBasket.removeAll { $0.path == path }
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
        externalBasket = []
    }

    /// Moves every basket item to the Trash and takes it out of the tree.
    func trashBasket() {
        guard !isBusy else { return }
        trashExternalItems()
        guard var tree else { return }
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
        refreshLargeFiles()
        if let path = lastScanPath { volume = VolumeInfo(path: path) }

        if !failures.isEmpty {
            alertMessage = "有 \(failures.count) 项没能移到废纸篓：\n" + failures.prefix(5).joined(separator: "\n")
        }
    }

    /// Items outside the scan go through Finder's own recycling, which asks for an
    /// administrator password where Finder would (apps installed from the App Store).
    private func trashExternalItems() {
        let items = externalBasket
        guard !items.isEmpty else { return }
        externalBasket = []
        NSWorkspace.shared.recycle(items.map { URL(fileURLWithPath: $0.path) }) { [weak self] recycled, error in
            Task { @MainActor in
                guard let self else { return }
                let failed = items.filter { recycled[URL(fileURLWithPath: $0.path)] == nil }
                if !failed.isEmpty {
                    self.alertMessage = "有 \(failed.count) 项没能移到废纸篓"
                        + (error.map { "：\($0.localizedDescription)" } ?? "")
                        + "\n" + failed.prefix(5).map(\.name).joined(separator: "\n")
                }
                self.externalItemsRecycled += 1
                if let path = self.lastScanPath { self.volume = VolumeInfo(path: path) }
            }
        }
    }

    /// Bumped after items outside the scan went to the Trash, so lists of apps can reload.
    private(set) var externalItemsRecycled = 0
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
