import DiskLensCore
import Foundation

let usage = """
    usage: disklens <path> [--top N] [--depth D] [--threads N] [--all-volumes] [--kb]

      --top N        largest N children to list per level (default 15)
      --depth D      how many levels to expand (default 1)
      --threads N    worker threads (default: number of CPU cores)
      --all-volumes  descend into other mounted volumes
      --kb           print only the total in 1024-byte blocks, like `du -sk`
    """

var path: String?
var top = 15
var depth = 1
var kbOnly = false
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
guard let path else {
    print(usage)
    exit(2)
}
let rootPath = (path as NSString).expandingTildeInPath

let tree: FileTree
do {
    tree = try Scanner(options: options).scan(rootPath)
} catch {
    FileHandle.standardError.write("disklens: \(error)\n".data(using: .utf8)!)
    exit(1)
}

if kbOnly {
    print(tree.totalSize / 1024)
    exit(0)
}

let s = tree.stats
print("\(tree.rootPath)")
print("Total \(ByteFormat.string(tree.totalSize))  ·  \(s.files) files  ·  \(s.directories) folders  ·  \(String(format: "%.2f", s.duration)) s")
if s.unreadableDirectories > 0 {
    print("Could not read \(s.unreadableDirectories) folders (grant Full Disk Access to the terminal to include them), e.g.:")
    for sample in s.unreadableSamples.prefix(3) { print("  \(sample)") }
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
