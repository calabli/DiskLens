// Builds a stand-in home folder of made-up but realistic data for screenshots:
//
//   swift scripts/make-demo-home.swift /tmp/demo-home
//   DISKLENS_DEMO_HOME=/tmp/demo-home build/DiskLens.app/Contents/MacOS/DiskLens --scan /tmp/demo-home
//
// Large files are APFS clones of a few base files, so ~250 GB of apparent data
// takes about 3 GB of real disk. Delete the folder and its "-bases" sibling after.
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("usage: swift scripts/make-demo-home.swift <empty-folder>")
    exit(2)
}
let home = URL(fileURLWithPath: args[1]).standardizedFileURL.path
let bases = home + "-bases"
let fm = FileManager.default
guard !fm.fileExists(atPath: home) else {
    print("\(home) already exists")
    exit(1)
}
try fm.createDirectory(atPath: bases, withIntermediateDirectories: true)

// MARK: Base files

let GB: Int64 = 1_000_000_000, MB: Int64 = 1_000_000
let baseSizes: [Int64] = [2 * GB, 500 * MB, 64 * MB, 8 * MB, MB, 128_000]
for size in baseSizes {
    let path = "\(bases)/\(size)"
    guard let out = FileHandle(forWritingAtPath: path) ?? {
        fm.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }() else { fatalError("cannot write \(path)") }
    var chunk = Data(count: Int(min(size, 8 * MB)))
    chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    var written: Int64 = 0
    while written < size {
        let part = chunk.prefix(Int(min(Int64(chunk.count), size - written)))
        out.write(part)
        written += Int64(part.count)
    }
    try out.close()
}

/// A copy of the base file of `size` at `path`, sharing its blocks.
func clone(_ size: Int64, to relative: String, modified: Date? = nil) {
    let path = home + "/" + relative
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard clonefile("\(bases)/\(size)", path, 0) == 0 else { fatalError("clonefile \(path): \(errno)") }
    if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
}

/// About `total` bytes in files of `size`, named by `name(i)`.
func fill(_ folder: String, _ total: Int64, with size: Int64, modified: Date? = nil, name: (Int) -> String) {
    let count = max(Int(total / size), 1)
    for i in 1...count { clone(size, to: folder + "/" + name(i), modified: modified) }
}

let now = Date()
func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

// MARK: Library: developer tools, caches and app data

let derived = "Library/Developer/Xcode/DerivedData"
fill("\(derived)/Lumen-ahfkqbxdmeywcrgoxzrlnmpa/Build/Intermediates.noindex/Lumen.build/Debug-iphonesimulator/Lumen.build/Objects-normal/arm64",
     5 * GB, with: 8 * MB) { "Module\($0).o" }
fill("\(derived)/Lumen-ahfkqbxdmeywcrgoxzrlnmpa/Index.noindex/DataStore/v5/units", 2 * GB, with: MB) { "unit-\($0)" }
fill("\(derived)/WeatherKit-dkehqzpwxtrbbqfhjyavmlu/Build/Products/Debug-iphoneos/WeatherKit.app", 3 * GB, with: 64 * MB) { "Frameworks\($0).dylib" }
fill("Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.5 (21F79)/Symbols/System/Library/PrivateFrameworks",
     4500 * MB, with: 64 * MB) { "Framework\($0).framework" }
fill("Library/Developer/Xcode/iOS DeviceSupport/iPhone16,1 18.0 (22A3354)/Symbols/System/Library/PrivateFrameworks",
     4600 * MB, with: 64 * MB) { "Framework\($0).framework" }
for (i, uuid) in ["4C1F2A9E-7D3B-4E8A-9F61-2B7C5D0E8A13", "9A0B6C2D-1E4F-4A7B-8C3D-5E6F7A8B9C0D"].enumerated() {
    fill("Library/Developer/CoreSimulator/Devices/\(uuid)/data/Containers/Bundle/Application",
         Int64(3 + i) * GB, with: 64 * MB) { "App\($0).app" }
}
clone(2 * GB, to: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
fill("Library/Caches/Homebrew/downloads", 4 * GB, with: 500 * MB) {
    ["llvm--19.1.0.arm64_sequoia.bottle.tar.gz", "ffmpeg--7.1.arm64_sequoia.bottle.tar.gz", "qt--6.7.3.bottle.tar.gz",
     "opencv--4.10.0.bottle.tar.gz", "rust--1.82.0.bottle.tar.gz", "gcc--14.2.0.bottle.tar.gz",
     "postgresql@16--16.4.bottle.tar.gz", "node--23.1.0.bottle.tar.gz"][($0 - 1) % 8]
}
fill("Library/Caches/com.spotify.client/Data", 2100 * MB, with: 8 * MB) { "track-\($0).file" }
fill("Library/Caches/Google/Chrome/Default/Cache/Cache_Data", 1600 * MB, with: MB) { String(format: "%016llx_0", UInt64($0) &* 2_654_435_761) }
fill("Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E6F70", 14 * GB, with: 8 * MB) { String(format: "%02x/%040x", $0 % 256, $0 &* 7919) }
fill("Library/Messages/Attachments", 6 * GB, with: MB) { String(format: "%02x/%02d/IMG_%04d.heic", $0 % 64, $0 % 16, $0) }
let wechat = "Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9/5f1c8e2a9b"
fill("\(wechat)/Message/MessageTemp/video", 6 * GB, with: 64 * MB) { "VID_2026\(String(format: "%04d", 900 + $0)).mp4" }
fill("\(wechat)/Message/MessageTemp/image", 3 * GB, with: MB) { "IMG_\($0).jpg" }
fill("Library/Logs/DiagnosticReports", 600 * MB, with: MB) { "Lumen-2026-10-\(String(format: "%02d", $0 % 28 + 1))-\($0).ips" }

// MARK: Media and documents

fill("Movies/Final Cut/Lumen 发布会.fcpbundle/Lumen 发布会/Original Media", 38 * GB, with: 500 * MB) {
    String(format: "A%03d_C%03d_2609%02d.mov", $0 / 20 + 1, $0, $0 % 28 + 1)
}
for (i, day) in ["2026-09-03 10.21.44", "2026-09-17 15.02.10", "2026-10-08 09.45.31", "2026-10-21 20.13.05"].enumerated() {
    clone(2 * GB, to: "Movies/屏幕录制/屏幕录制 \(day).mov", modified: daysAgo(Double(50 - i * 12)))
}
fill("Pictures/Photos Library.photoslibrary/originals", 52 * GB, with: 8 * MB) {
    String(format: "%X/%08X-%04X-4%03X-9%03X.heic", $0 % 16, $0 &* 2_654_435_761, $0 % 65_536, $0 % 4096, ($0 * 7) % 4096)
}
fill("Music/Logic/Lumen 主题曲.logicx/Media/Audio Files", 4 * GB, with: 64 * MB) { "Track \($0)#01.wav" }
clone(500 * MB, to: "Documents/工作/2026 Q3 汇报.key")
fill("Documents/工作/设计稿", 3 * GB, with: 64 * MB) { "Lumen v\($0 / 10 + 2).\($0 % 10).sketch" }
fill("Documents/论文资料", 1600 * MB, with: 8 * MB) { "paper-\($0).pdf" }
fill("Documents/合同", 50 * MB, with: MB) { "合同-\($0).pdf" }

// MARK: Projects, one untouched for months

let stale = daysAgo(140)
fill("Projects/lumen-web/node_modules", 2400 * MB, with: MB, modified: stale) {
    ["react-dom", "next", "typescript", "@babel/core", "esbuild", "webpack", "@swc/core", "prettier"][$0 % 8] + "/dist/chunk-\($0).js"
}
clone(128_000, to: "Projects/lumen-web/package.json", modified: stale)
clone(128_000, to: "Projects/lumen-web/src/index.tsx", modified: stale)
fill("Projects/lumen-web/.next/cache", 900 * MB, with: 8 * MB, modified: stale) { "webpack-\($0).pack" }
for path in ["Projects/lumen-web/node_modules", "Projects/lumen-web/.next", "Projects/lumen-web/src", "Projects/lumen-web"] {
    try? fm.setAttributes([.modificationDate: stale], ofItemAtPath: home + "/" + path)
}
fill("Projects/ml-experiments/checkpoints", 12 * GB, with: 500 * MB) { "epoch-\(String(format: "%03d", $0)).pt" }
fill("Projects/ml-experiments/datasets/coco-2017", 6 * GB, with: 8 * MB) { "train-\($0).tfrecord" }
fill("Projects/ios-client/Pods", 1200 * MB, with: MB) { "Pod\($0 % 40)/Sources/File\($0).swift" }
fill("Projects/ios-client/build", 3 * GB, with: 64 * MB) { "Intermediates/obj-\($0).o" }
fill(".npm/_cacache/content-v2/sha512", 3 * GB, with: MB) { String(format: "%02x/%02x/%060x", $0 % 256, ($0 / 7) % 256, $0 &* 104_729) }
fill(".gradle/caches/modules-2/files-2.1", 2 * GB, with: 8 * MB) { "lib-\($0).jar" }

// MARK: Downloads, with a few true duplicates

for (name, size) in [("Xcode_16.1.xip", 2 * GB), ("ubuntu-24.04.1-desktop-arm64.iso", 2 * GB), ("旅行素材.zip", 2 * GB),
                     ("Docker.dmg", 500 * MB), ("WeChatMac.dmg", 500 * MB), ("Figma-124.5.dmg", 500 * MB)] {
    clone(size, to: "Downloads/\(name)", modified: daysAgo(Double(name.count)))
}
for (original, copies) in [("Documents/合同/租房合同.pdf", ["Downloads/租房合同.pdf", "Downloads/租房合同(1).pdf"]),
                           ("Documents/工作/品牌手册.pdf", ["Downloads/品牌手册.pdf"]),
                           ("Pictures/婚礼/DSC_0412.jpg", ["Desktop/DSC_0412 copy.jpg"])] {
    try fm.createDirectory(atPath: (home + "/" + original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try fm.copyItem(atPath: "\(bases)/\(8 * MB)", toPath: home + "/" + original)
    for copy in copies {
        try fm.createDirectory(atPath: (home + "/" + copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: home + "/" + original, toPath: home + "/" + copy)
    }
}

// MARK: DiskLens's own data: a cleanup history and a month of recorded activity

let support = home + "/Library/Application Support/app.disklens.DiskLens"
try fm.createDirectory(atPath: support, withIntermediateDirectories: true)
clone(2 * GB, to: ".Trash/DerivedData")
clone(500 * MB, to: ".Trash/Simulator Caches")
clone(64 * MB, to: ".Trash/Lumen-2026-10-02.ips")
func item(_ original: String, _ trash: String, _ size: Int64, _ dir: Bool, restored: Bool = false) -> [String: Any] {
    var item: [String: Any] = ["originalPath": home + "/" + original, "trashPath": home + "/" + trash, "size": size, "isDirectory": dir]
    if restored { item["restoredAt"] = ISO8601DateFormatter().string(from: daysAgo(0.9)) }
    return item
}
let iso = ISO8601DateFormatter()
let log: [[String: Any]] = [
    ["id": UUID().uuidString, "date": iso.string(from: daysAgo(1)), "items": [
        item("Library/Developer/Xcode/DerivedData", ".Trash/DerivedData", 9_400 * MB, true),
        item("Library/Developer/CoreSimulator/Caches", ".Trash/Simulator Caches", 1_800 * MB, true),
        item("Library/Logs/DiagnosticReports/Lumen-2026-10-02.ips", ".Trash/Lumen-2026-10-02.ips", 64 * MB, false),
        item("Documents/工作/2026 Q2 汇报.key", ".Trash/2026 Q2 汇报.key", 480 * MB, false, restored: true),
    ]],
    ["id": UUID().uuidString, "date": iso.string(from: daysAgo(12)), "items": [
        item("Downloads/Xcode_16.0.xip", ".Trash/Xcode_16.0.xip", 3_100 * MB, false),
        item("Library/Caches/Homebrew/downloads", ".Trash/downloads", 2_600 * MB, true),
    ]],
]
try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: support + "/cleanup-log.json"))

// Volume use rising over 30 days, with the two days something big landed.
var sql = ["BEGIN;"]
let lastHour = Int64(now.timeIntervalSince1970) / 3600 * 3600
var used: Int64 = 361 * GB
let total: Int64 = 994 * GB
let apps: [(String, Int64, String)] = [("Xcode", 900 * MB, "Library/Developer"), ("Docker", 300 * MB, "Library/Containers/com.docker.docker"),
                                       ("Google Chrome", 120 * MB, "Library/Caches/Google"), ("微信", 200 * MB, wechat),
                                       ("Final Cut Pro", 60 * MB, "Movies/Final Cut")]
for hour in stride(from: lastHour - 30 * 86_400, through: lastHour, by: 3600) {
    let hoursAgo = (lastHour - hour) / 3600
    let daytime = (9...22).contains(Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(hour))))
    var grown: Int64 = 0
    for (index, (app, perHour, folder)) in apps.enumerated() {
        var bytes = daytime ? perHour / 4 + Int64((hoursAgo * 37 + Int64(index) * 11) % 9) * perHour / 12 : perHour / 30
        if app == "Docker" && hoursAgo == 9 * 24 + 5 { bytes = 6_200 * MB }
        if app == "Final Cut Pro" && hoursAgo == 4 * 24 + 3 { bytes = 4_800 * MB }
        sql.append("INSERT INTO writes VALUES (\(hour), '\(app)', \(bytes * 3));")
        let growth = bytes * 2 / 3
        grown += growth
        sql.append("INSERT INTO growth VALUES (\(hour), '\(home)/\(folder)', '\(app)', \(growth));")
    }
    used += grown - (hoursAgo == 24 ? 14_000 * MB : 0) - (hoursAgo == 12 * 24 ? 5_700 * MB : 0)
    sql.append("INSERT INTO volume VALUES (\(hour), \(used), \(total - used));")
}
sql.append("INSERT INTO meta VALUES ('agent.fullDiskAccess', 'granted', \(Int64(now.timeIntervalSince1970)));")
sql.append("COMMIT;")
let schema = """
    CREATE TABLE writes (minute INTEGER, app TEXT, bytes INTEGER, PRIMARY KEY (minute, app));
    CREATE TABLE growth (minute INTEGER, folder TEXT, owner TEXT, bytes INTEGER, PRIMARY KEY (minute, folder));
    CREATE TABLE volume (minute INTEGER PRIMARY KEY, used INTEGER, available INTEGER);
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT, updated INTEGER);
    """
let sqlite = Process()
sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
sqlite.arguments = [support + "/activity.sqlite"]
let input = Pipe()
sqlite.standardInput = input
try sqlite.run()
input.fileHandleForWriting.write(Data((schema + sql.joined(separator: "\n")).utf8))
try input.fileHandleForWriting.close()
sqlite.waitUntilExit()

print("Demo home ready at \(home) (base files in \(bases))")
