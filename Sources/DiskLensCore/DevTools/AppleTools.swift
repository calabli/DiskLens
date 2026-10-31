import CoreServices
import Foundation

/// Xcode installs, simulators and their runtimes, device support files and DerivedData.
enum AppleTools {
    static func discover(_ context: DevContext) -> DevGroup {
        var items: [DevItem] = []
        items += xcodes(context)
        let devices = context.output("xcrun", ["simctl", "list", "devices", "--json"]).flatMap { parseDevices(Data($0.utf8)) } ?? []
        items += devices.map { simulator($0, context) }
        let runtimes = context.output("xcrun", ["simctl", "runtime", "list", "-j"]).flatMap { parseRuntimes(Data($0.utf8)) } ?? []
        items += runtimes.map { runtime($0, devices: devices) }
        items += deviceSupport(context)
        items += derivedData(context)
        let note = items.isEmpty ? "没有找到 Xcode 或它的数据。" : nil
        return DevGroup(ecosystem: .apple, items: items, note: note)
    }

    // MARK: Xcode

    private static func xcodes(_ context: DevContext) -> [DevItem] {
        let selected = context.output("xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let roots = (context.looksOutsideHome ? ["/Applications"] : []) + [context.home + "/Applications"]
        return roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
                .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
                .map { root + "/" + $0 }
        }.compactMap { path -> DevItem? in
            guard let bundle = Bundle(path: path), bundle.bundleIdentifier == "com.apple.dt.Xcode" else { return nil }
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            let isSelected = selected.map { $0.hasPrefix(path + "/") } ?? false
            return DevItem(id: "xcode:" + path, ecosystem: .apple, kind: "Xcode",
                           title: (path as NSString).lastPathComponent, detail: version.map { "版本 \($0)" },
                           path: path, size: context.size(of: path), lastUsed: lastOpened(path),
                           usage: isSelected ? .active("当前使用（xcode-select）") : .unknown,
                           removal: .trash(path),
                           consequence: "这个版本的 Xcode 会被移到废纸篓；用它编译的项目需要改用其他版本。")
        }
    }

    private static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Simulators

    struct Device: Equatable {
        let udid: String
        let name: String
        let runtime: String
        let state: String
        let isAvailable: Bool
        let dataPath: String?
        let dataSize: Int64?
        let lastBooted: Date?
    }

    /// `xcrun simctl list devices --json`.
    static func parseDevices(_ data: Data) -> [Device]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return nil }
        let iso = ISO8601DateFormatter()
        return byRuntime.flatMap { runtime, devices in
            devices.compactMap { d -> Device? in
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
                return Device(udid: udid, name: name, runtime: runtime, state: d["state"] as? String ?? "",
                              isAvailable: d["isAvailable"] as? Bool ?? true, dataPath: d["dataPath"] as? String,
                              dataSize: (d["dataPathSize"] as? NSNumber)?.int64Value,
                              lastBooted: (d["lastBootedAt"] as? String).flatMap(iso.date(from:)))
            }
        }.sorted { $0.name < $1.name }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5".
    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : String(platform)
    }

    private static func simulator(_ device: Device, _ context: DevContext) -> DevItem {
        let usage: DevItem.Usage = if device.state == "Booted" {
            .active("正在运行")
        } else if !device.isAvailable {
            .unused("系统版本已删除，不能再启动")
        } else {
            .unknown
        }
        return DevItem(id: "simulator:" + device.udid, ecosystem: .apple, kind: "模拟器",
                       title: device.name, detail: runtimeName(device.runtime), path: device.dataPath,
                       size: device.dataSize ?? device.dataPath.flatMap(context.size(of:)), lastUsed: device.lastBooted,
                       usage: usage, removal: .command(ToolCommand("xcrun", ["simctl", "delete", device.udid])),
                       consequence: "这台模拟器和装在里面的应用、数据会被删除；需要时可以在 Xcode 里重新创建。")
    }

    struct Runtime: Equatable {
        let identifier: String
        let runtimeIdentifier: String
        let version: String
        let build: String
        let size: Int64?
        let lastUsed: Date?
        let deletable: Bool
        let path: String?
    }

    /// `xcrun simctl runtime list -j`: an object keyed by the runtime's UUID.
    static func parseRuntimes(_ data: Data) -> [Runtime]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return root.compactMap { key, r -> Runtime? in
            guard let runtimeID = r["runtimeIdentifier"] as? String else { return nil }
            let used = (r["lastUsedAt"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return Runtime(identifier: r["identifier"] as? String ?? key, runtimeIdentifier: runtimeID,
                           version: r["version"] as? String ?? "", build: r["build"] as? String ?? "",
                           size: (r["sizeBytes"] as? NSNumber)?.int64Value, lastUsed: used,
                           deletable: r["deletable"] as? Bool ?? false, path: r["path"] as? String)
        }.sorted { $0.runtimeIdentifier < $1.runtimeIdentifier }
    }

    private static func runtime(_ runtime: Runtime, devices: [Device]) -> DevItem {
        let users = devices.filter { $0.runtime == runtime.runtimeIdentifier }.count
        let name = runtimeName(runtime.runtimeIdentifier)
        return DevItem(id: "runtime:" + runtime.identifier, ecosystem: .apple, kind: "模拟器系统",
                       title: name, detail: runtime.build.isEmpty ? nil : "构建 \(runtime.build)", path: runtime.path,
                       size: runtime.size, lastUsed: runtime.lastUsed,
                       usage: users > 0 ? .used("\(users) 台模拟器在用") : .unused("没有模拟器在用"),
                       removal: runtime.deletable
                           ? .command(ToolCommand("xcrun", ["simctl", "runtime", "delete", runtime.identifier]))
                           : .none("随 Xcode 一起安装，不能单独删除"),
                       consequence: "用这个系统版本的模拟器将无法启动；需要时可以在 Xcode 的设置里重新下载。")
    }

    // MARK: Device support and DerivedData

    private static func deviceSupport(_ context: DevContext) -> [DevItem] {
        let base = context.home + "/Library/Developer/Xcode"
        let platforms = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).filter { $0.hasSuffix(" DeviceSupport") }
        return platforms.flatMap { platform in
            let folders = context.subfolders(of: base + "/" + platform)
            // A device that was updated leaves the symbols of its older system versions behind.
            let newest = newestPerDevice(folders.map { ($0 as NSString).lastPathComponent }, modified: {
                context.modified(base + "/" + platform + "/" + $0)
            })
            return folders.map { path in
                let name = (path as NSString).lastPathComponent
                let usage: DevItem.Usage = newest.contains(name) ? .used("这台设备最新的一份") : .unused("这台设备已有更新的系统版本")
                return DevItem(id: "devicesupport:" + path, ecosystem: .apple, kind: "设备调试符号",
                               title: name, detail: platform.replacingOccurrences(of: " DeviceSupport", with: ""),
                               path: path, size: context.size(of: path), lastUsed: context.modified(path), usage: usage,
                               removal: .trash(path),
                               consequence: "再连接这个系统版本的设备调试时，Xcode 会重新下载，需要几分钟。")
            }
        }
    }

    /// Device support folders are named "iPhone16,1 27.0.1 (24A446)": the model, then the
    /// system version. Per model, the highest system version is the one in use; folders
    /// without a readable version fall back to the one made last.
    static func newestPerDevice(_ names: [String], modified: (String) -> Date?) -> Set<String> {
        let parts = { (name: String) in name.split(separator: " ").map(String.init) }
        let byModel = Dictionary(grouping: names) { parts($0).first ?? $0 }
        return Set(byModel.values.compactMap { group in
            group.max { a, b in
                let va = parts(a).dropFirst().first, vb = parts(b).dropFirst().first
                if let va, let vb, va != vb, va.first?.isNumber == true, vb.first?.isNumber == true {
                    return SoftwareUpdate.isNewer(vb, than: va)
                }
                return (modified(a) ?? .distantPast) < (modified(b) ?? .distantPast)
            }
        })
    }

    private static func derivedData(_ context: DevContext) -> [DevItem] {
        let base = context.home + "/Library/Developer/Xcode/DerivedData"
        return context.subfolders(of: base).map { path in
            let info = NSDictionary(contentsOfFile: path + "/info.plist")
            let workspace = info?["WorkspacePath"] as? String
            let accessed = info?["LastAccessedDate"] as? Date ?? context.modified(path)
            let usage: DevItem.Usage = workspace.map {
                FileManager.default.fileExists(atPath: $0) ? .used("项目还在") : .unused("项目已不存在")
            } ?? .unknown
            let folder = (path as NSString).lastPathComponent
            // "Balance-dcpdfurxzfyvaleftwwznpamjqlg" → "Balance"; shared caches such as "SymbolCache.noindex" keep their name.
            let project = folder.range(of: #"-[a-z]{28}$"#, options: .regularExpression).map { String(folder[..<$0.lowerBound]) }
            let name = workspace.map { ($0 as NSString).lastPathComponent } ?? project ?? folder
            return DevItem(id: "derived:" + path, ecosystem: .apple, kind: workspace == nil && project == nil ? "Xcode 共享缓存" : "编译缓存", title: name,
                           detail: workspace.map { ($0 as NSString).deletingLastPathComponent.abbreviatingHome },
                           path: path, size: context.size(of: path), lastUsed: accessed, usage: usage,
                           removal: .trash(path),
                           consequence: "下次打开这个项目时会重新编译和建立索引，第一次会慢一些。")
        }
    }
}
