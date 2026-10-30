import Foundation

/// Homebrew's installed packages, old versions and download cache.
enum HomebrewTools {
    static func discover(_ context: DevContext) -> DevGroup {
        guard ToolCommand("brew", []).isInstalled,
              let prefix = context.output("brew", ["--prefix"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return DevGroup(ecosystem: .homebrew, items: [], note: "没有安装 Homebrew。") }
        var items: [DevItem] = []

        let cleanup = context.output("brew", ["cleanup", "-n"], timeout: 60).map(parseCleanupTotal) ?? nil
        if let cleanup, cleanup > 0 {
            items.append(DevItem(id: "brew:cleanup", ecosystem: .homebrew, kind: "旧版本", title: "旧版本和过期的下载",
                                 detail: "已经被新版本替代的包、超过 120 天的下载", size: cleanup,
                                 usage: .unused("已被新版本替代"),
                                 removal: .command(ToolCommand("brew", ["cleanup"])),
                                 consequence: "只删除旧版本和过期文件，正在使用的版本不受影响。"))
        }
        if let cache = context.output("brew", ["--cache"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           let size = context.size(of: cache), size > 0 {
            items.append(DevItem(id: "brew:cache", ecosystem: .homebrew, kind: "下载缓存", title: "全部下载缓存",
                                 detail: cache.abbreviatingHome, path: cache, size: size, usage: .regenerable("可以重新下载"),
                                 removal: .command(ToolCommand("brew", ["cleanup", "--prune=all"])),
                                 consequence: "已下载的安装包都会删除；以后安装或升级时重新下载。"))
        }
        for (folder, kind, title) in [("Cellar", "已安装的包", "命令行工具（Cellar）"),
                                      ("Caskroom", "已安装的应用", "应用（Caskroom）")] {
            let path = prefix + "/" + folder
            let count = context.subfolders(of: path).count
            guard count > 0 else { continue }
            items.append(DevItem(id: "brew:" + folder, ecosystem: .homebrew, kind: kind, title: title,
                                 detail: "\(count) 个", path: path, size: context.size(of: path),
                                 usage: .active("已安装"),
                                 removal: .none("用 brew uninstall 卸载不需要的包"), consequence: ""))
        }
        return DevGroup(ecosystem: .homebrew, items: items)
    }

    /// The total from `brew cleanup -n`: "==> This operation would free approximately 52.2MB of disk space."
    static func parseCleanupTotal(_ text: String) -> Int64? {
        guard let range = text.range(of: #"free approximately ([0-9.,]+\s*[KMGT]?B)"#, options: .regularExpression) else {
            return text.contains("Would remove") ? nil : 0
        }
        let match = String(text[range]).replacingOccurrences(of: "free approximately ", with: "")
        return DevEnvironmentScanner.parseSize(match)
    }
}
