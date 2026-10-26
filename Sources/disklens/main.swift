import DiskLensCore
import Foundation

let usage = """
    usage: disklens <path> [--top N] [--depth D] [--threads N] [--all-volumes] [--kb] [--suggest] [--use-cache] [--duplicates]

      --top N        largest N children to list per level (default 15)
      --depth D      how many levels to expand (default 1)
      --threads N    worker threads (default: number of CPU cores)
      --all-volumes  descend into other mounted volumes
      --kb           print only the total in 1024-byte blocks, like `du -sk`
      --suggest      print cleanup suggestions instead of the largest items
      --app NAME     list everything an installed app has on disk (no path needed)
      --duplicates   list files with identical contents (1 MB and larger, outside ~/Library)
      --use-cache    update the saved scan from the change journal instead of rescanning,
                     then print what changed and save the new result
    """

var path: String?
var top = 15
var depth = 1
var kbOnly = false
var suggest = false
var useCache = false
var duplicates = false
var appQuery: String?
var options = ScanOptions()

var args = CommandLine.arguments.dropFirst().makeIterator()
@MainActor func intArg(_ flag: String) -> Int {
    guard let raw = args.next(), let value = Int(raw), value > 0 else {
        FileHandle.standardError.write("\(flag) needs a positive number\n".data(using: .utf8)!)
        exit(2)
    }
    return value
}
while let arg = args.next() {
    switch arg {
    case "--top": top = intArg(arg)
    case "--depth": depth = intArg(arg)
    case "--threads": options.threadCount = intArg(arg)
    case "--all-volumes": options.stayOnVolume = false
    case "--kb": kbOnly = true
    case "--suggest": suggest = true
    case "--use-cache": useCache = true
    case "--duplicates": duplicates = true
    case "--app":
        appQuery = args.next()
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if arg.hasPrefix("-") || path != nil {
            print(usage)
            exit(2)
        }
        path = arg
    }
}
guard let path = path ?? (appQuery != nil ? "~" : nil) else {
    print(usage)
    exit(2)
}
if let appQuery {
    // `disklens --app <name>`: list everything an app has on disk.
    let installed = AppCatalog.installedApps()
    guard let app = installed.first(where: { $0.name.localizedCaseInsensitiveContains(appQuery) }) else {
        print("no installed app matches \(appQuery)")
        exit(1)
    }
    let started = Date()
    let footprint = AppFootprintFinder(installed: installed).footprint(of: app)
    print("\(app.name) \(app.version ?? "") · \(app.bundleID) · team \(app.teamID ?? "-") · helpers \(app.helperIDs.count)")
    print("app \(ByteFormat.string(footprint.files[0].size)) + data \(ByteFormat.string(footprint.dataSize)) · \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n")
    for file in footprint.files.dropFirst() {
        let flags = (file.confidence == .certain ? "certain" : "likely ") + (file.requiresAdmin ? " admin" : "")
        print("  \(ByteFormat.string(file.size).padding(toLength: 9, withPad: " ", startingAt: 0)) \(flags)  \((file.path as NSString).abbreviatingWithTildeInPath)")
    }
    if let command = footprint.adminCommand { print("\nadmin:\n\(command)") }
    exit(0)
}
let rootPath = (path as NSString).expandingTildeInPath

func seconds(since start: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(start)) }

let tree: FileTree
do {
    if useCache {
        let cache = ScanCache.standard
        let eventID = ChangeJournal.currentEventID()
        let journalID = ChangeJournal.journalID(for: rootPath)
        var started = Date()
        if let cached = cache.load(rootPath: rootPath) {
            print("loaded cached scan from \(cached.scannedAt.formatted()) in \(seconds(since: started))")
            started = Date()
            let changes = cached.journalID == journalID
                ? ChangeJournal.changes(under: rootPath, since: cached.eventID) : nil
            if let changes {
                print("journal: \(changes.folders.count) changed folders, \(changes.subtrees.count) subtrees in \(seconds(since: started))")
                started = Date()
                tree = try TreeUpdater.update(cached.tree, applying: changes, options: options)
                print("updated in \(seconds(since: started))")
            } else {
                print("journal unavailable, scanning everything")
                tree = try DiskScanner(options: options).scan(rootPath)
            }
            let comparison = ScanComparison(previous: cached.tree, previousDate: cached.scannedAt, current: tree)
            print("since last scan: \(comparison.delta >= 0 ? "+" : "-")\(ByteFormat.string(abs(comparison.delta)))")
            for change in comparison.changes.prefix(top) {
                let sign = change.delta >= 0 ? "+" : "-"
                print("  \(sign)\(ByteFormat.string(abs(change.delta)).padding(toLength: 9, withPad: " ", startingAt: 0)) \(change.path)")
            }
        } else {
            tree = try DiskScanner(options: options).scan(rootPath)
            print("no cached scan; scanned in \(seconds(since: started))")
        }
        started = Date()
        try cache.save(CachedScan(tree: tree, scannedAt: Date(), eventID: eventID, journalID: journalID))
        print("saved to \(cache.url(forRoot: rootPath).path) in \(seconds(since: started))\n")
    } else {
        tree = try DiskScanner(options: options).scan(rootPath)
    }
} catch {
    FileHandle.standardError.write("disklens: \(error)\n".data(using: .utf8)!)
    exit(1)
}

if kbOnly {
    print(tree.totalSize / 1024)
    exit(0)
}

if duplicates {
    let started = Date()
    let groups = try DuplicateFinder().find(in: tree)
    let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
    print("\(groups.count) groups of duplicates, \(ByteFormat.string(reclaimable)) reclaimable, found in \(seconds(since: started))\n")
    for group in groups.prefix(top) {
        let clones = group.isMostlyClones ? "  (APFS clones, little to gain)" : ""
        print("\(ByteFormat.string(group.reclaimable).padding(toLength: 9, withPad: " ", startingAt: 0)) \(group.files.count) × \(ByteFormat.string(group.size))\(clones)")
        for file in group.files {
            print("      \(file == group.files.first ? "keep" : "    ") \((file.path as NSString).abbreviatingWithTildeInPath)")
        }
    }
    exit(0)
}

if suggest {
    let installed = InstalledApps.discover()
    let advisor = CleanupAdvisor { installed.isInstalled($0) }
    let rules = (try? CleanupRuleSet.bundled().rules) ?? []
    let started = Date()
    let suggestions = advisor.suggestions(for: tree, rules: rules)
    print("\(suggestions.count) suggestions in \(String(format: "%.2f", Date().timeIntervalSince(started))) s\n")
    for suggestion in suggestions {
        let action = suggestion.command.map { "  $ \($0)" } ?? ""
        print("[\(suggestion.safety.rawValue)] \(ByteFormat.string(suggestion.totalSize).padding(toLength: 9, withPad: " ", startingAt: 0)) \(suggestion.title)\(action)")
        for item in suggestion.items.prefix(top) {
            let date = item.lastModified.map { "  (last change \($0.formatted(date: .numeric, time: .omitted)))" } ?? ""
            print("      \(ByteFormat.string(item.size).padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.label)\(date)")
        }
        if suggestion.items.count > top { print("      … \(suggestion.items.count - top) more") }
    }
    exit(0)
}

let s = tree.stats
print("\(tree.rootPath)")
print("Total \(ByteFormat.string(tree.totalSize))  ·  \(s.files) files  ·  \(s.directories) folders  ·  \(String(format: "%.2f", s.duration)) s")
if s.unreadableDirectories > 0 {
    print("Could not read \(s.unreadableDirectories) folders (grant Full Disk Access to the terminal to include them), e.g.:")
    for folder in s.unreadable.prefix(3) { print("  \(folder.path)") }
}
if s.skippedMounts > 0 { print("Skipped \(s.skippedMounts) folders on other volumes (use --all-volumes to include)") }
if s.duplicateHardLinks > 0 { print("Counted \(s.duplicateHardLinks) hard links once") }
print("")

@MainActor func printChildren(of node: Int, level: Int) {
    let total = max(tree.totalSizes[node], 1)
    let children = tree.children(of: node)
    for child in children.prefix(top) {
        let c = Int(child)
        let size = tree.totalSizes[c]
        let share = Double(size) / Double(total) * 100
        let indent = String(repeating: "  ", count: level)
        let suffix = tree.kinds[c] == .directory ? "/" : ""
        let sizeText = ByteFormat.string(size).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(indent)\(sizeText) \(String(format: "%5.1f%%", share))  \(tree.names[c])\(suffix)")
        if level + 1 < depth && tree.kinds[c] == .directory {
            printChildren(of: c, level: level + 1)
        }
    }
    if children.count > top {
        let rest = children.dropFirst(top).reduce(Int64(0)) { $0 + tree.totalSizes[Int($1)] }
        let indent = String(repeating: "  ", count: level)
        print("\(indent)\(ByteFormat.string(rest).padding(toLength: 10, withPad: " ", startingAt: 0))         … \(children.count - top) more")
    }
}
printChildren(of: 0, level: 0)
