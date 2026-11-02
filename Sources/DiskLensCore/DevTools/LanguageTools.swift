import Foundation

/// Node versions from nvm, fnm and Volta, and the npm, pnpm and Yarn caches.
enum NodeTools {
    static func discover(_ context: DevContext) -> DevGroup {
        let wanted = context.projectVersions(in: [".nvmrc", ".node-version"])
        var items: [DevItem] = []

        // nvm: ~/.nvm/versions/node/v20.11.0; the default is an alias such as "20" or "v20.11.0".
        let nvm = context.home + "/.nvm"
        let nvmDefault = context.firstLine(nvm + "/alias/default")
        for path in context.subfolders(of: nvm + "/versions/node") {
            let version = (path as NSString).lastPathComponent
            let isDefault = nvmDefault.map { DevContext.version($0, matches: version) } ?? false
            items.append(versionItem("nvm", version, path, isDefault: isDefault, wanted: wanted, context))
        }
        // fnm: .../fnm/node-versions/v20.11.0/installation; the default alias is a link to one of them.
        for base in [context.home + "/Library/Application Support/fnm", context.home + "/.local/share/fnm", context.home + "/.fnm"] {
            let defaultTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: base + "/aliases/default")
            for path in context.subfolders(of: base + "/node-versions") {
                let version = (path as NSString).lastPathComponent
                let isDefault = defaultTarget.map { $0.contains("/" + version + "/") || $0.hasSuffix("/" + version) } ?? false
                items.append(versionItem("fnm", version, path, isDefault: isDefault, wanted: wanted, context))
            }
        }
        // Volta: ~/.volta/tools/image/node/20.11.0; the default is in tools/user/platform.json.
        let volta = context.home + "/.volta/tools"
        let platform = (try? Data(contentsOf: URL(fileURLWithPath: volta + "/user/platform.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let voltaDefault = ((platform?["node"] as? [String: Any])?["runtime"] as? String)
        for path in context.subfolders(of: volta + "/image/node") {
            let version = (path as NSString).lastPathComponent
            items.append(versionItem("Volta", version, path, isDefault: version == voltaDefault, wanted: wanted, context))
        }

        for (path, title, command, program) in [
            (context.home + "/.npm/_cacache", L("npm 缓存"), ["cache", "clean", "--force"], "npm"),
            (context.home + "/Library/pnpm/store", L("pnpm 存储"), ["store", "prune"], "pnpm"),
            (context.home + "/Library/Caches/Yarn", L("Yarn 缓存"), ["cache", "clean"], "yarn"),
        ] {
            guard let size = context.size(of: path), size > 0 else { continue }
            let tool = ToolCommand(program, command)
            items.append(DevItem(id: "node:" + path, ecosystem: .node, kind: L("缓存"), title: title, detail: path.abbreviatingHome,
                                 path: path, size: size, lastUsed: context.modified(path), usage: .regenerable(L("可以重新下载")),
                                 removal: tool.isInstalled ? .command(tool) : .trash(path),
                                 consequence: L("下次安装依赖时会重新下载，第一次会慢一些。")))
        }
        return DevGroup(ecosystem: .node, items: items)
    }

    private static func versionItem(_ manager: String, _ version: String, _ path: String, isDefault: Bool,
                                    wanted: [String], _ context: DevContext) -> DevItem {
        DevItem(id: "node:\(manager):" + path, ecosystem: .node, kind: L("Node 版本"), title: "Node \(version)",
                detail: L("由 \(manager) 安装"), path: path, size: context.size(of: path), lastUsed: context.modified(path),
                usage: context.usage(of: version, isDefault: isDefault, wanted: wanted),
                removal: .trash(path),
                consequence: L("这个版本的 Node 和全局装在它下面的命令行工具会被移到废纸篓；需要时用 \(manager) 重新安装。"))
    }
}

/// Python versions from pyenv, conda environments and package caches, and the pip and uv caches.
enum PythonTools {
    static func discover(_ context: DevContext) -> DevGroup {
        let wanted = context.projectVersions(in: [".python-version"])
        var items: [DevItem] = []

        let pyenv = context.home + "/.pyenv"
        let global = context.firstLine(pyenv + "/version")
        let hasPyenv = ToolCommand("pyenv", []).isInstalled
        for path in context.subfolders(of: pyenv + "/versions") {
            let version = (path as NSString).lastPathComponent
            items.append(DevItem(id: "pyenv:" + path, ecosystem: .python, kind: L("Python 版本"), title: "Python \(version)",
                                 detail: L("由 pyenv 安装"), path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                 usage: context.usage(of: version, isDefault: version == global, wanted: wanted),
                                 removal: hasPyenv ? .command(ToolCommand("pyenv", ["uninstall", "-f", version])) : .trash(path),
                                 consequence: L("这个版本的 Python 和装在它里面的包会被删除；需要时用 pyenv install 重新安装。")))
        }

        for base in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/anaconda3", "opt/miniconda3"].map({ context.home + "/" + $0 }) {
            let conda = base + "/bin/conda"
            guard FileManager.default.isExecutableFile(atPath: conda) else { continue }
            let name = (base as NSString).lastPathComponent
            for path in context.subfolders(of: base + "/envs") {
                let env = (path as NSString).lastPathComponent
                items.append(DevItem(id: "conda:" + path, ecosystem: .python, kind: L("conda 环境"), title: env,
                                     detail: L("\(name) 的环境"), path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                     removal: .command(ToolCommand(conda, ["env", "remove", "-y", "-p", path])),
                                     consequence: L("这个环境和装在里面的包会被删除；依赖它的项目需要重新创建环境。")))
            }
            let pkgs = base + "/pkgs"
            if let size = context.size(of: pkgs), size > 0 {
                items.append(DevItem(id: "conda:pkgs:" + base, ecosystem: .python, kind: L("缓存"), title: L("\(name) 包缓存"),
                                     detail: pkgs.abbreviatingHome, path: pkgs, size: size, usage: .regenerable(L("可以重新下载")),
                                     removal: .command(ToolCommand(conda, ["clean", "--all", "-y"])),
                                     consequence: L("只清理下载过的安装包和用不到的旧包，已有的环境不受影响。")))
            }
        }

        for (path, title, tool) in [
            (context.home + "/Library/Caches/pip", L("pip 缓存"), ToolCommand("pip3", ["cache", "purge"])),
            (context.home + "/.cache/uv", L("uv 缓存"), ToolCommand("uv", ["cache", "clean"])),
        ] {
            guard let size = context.size(of: path), size > 0 else { continue }
            items.append(DevItem(id: "python:" + path, ecosystem: .python, kind: L("缓存"), title: title, detail: path.abbreviatingHome,
                                 path: path, size: size, lastUsed: context.modified(path), usage: .regenerable(L("可以重新下载")),
                                 removal: tool.isInstalled ? .command(tool) : .trash(path),
                                 consequence: L("下次安装包时会重新下载。")))
        }
        return DevGroup(ecosystem: .python, items: items)
    }
}

/// Ruby versions from rbenv and RVM.
enum RubyTools {
    static func discover(_ context: DevContext) -> DevGroup {
        let wanted = context.projectVersions(in: [".ruby-version"])
        var items: [DevItem] = []
        let global = context.firstLine(context.home + "/.rbenv/version")
        let hasRbenv = ToolCommand("rbenv", []).isInstalled
        for path in context.subfolders(of: context.home + "/.rbenv/versions") {
            let version = (path as NSString).lastPathComponent
            items.append(DevItem(id: "rbenv:" + path, ecosystem: .ruby, kind: L("Ruby 版本"), title: "Ruby \(version)",
                                 detail: L("由 rbenv 安装"), path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                 usage: context.usage(of: version, isDefault: version == global, wanted: wanted),
                                 removal: hasRbenv ? .command(ToolCommand("rbenv", ["uninstall", "-f", version])) : .trash(path),
                                 consequence: L("这个版本的 Ruby 和装在它下面的 gem 会被删除；需要时用 rbenv install 重新安装。")))
        }
        let rvmDefault = try? FileManager.default.destinationOfSymbolicLink(atPath: context.home + "/.rvm/rubies/default")
        for path in context.subfolders(of: context.home + "/.rvm/rubies") where !path.hasSuffix("/default") {
            let name = (path as NSString).lastPathComponent
            items.append(DevItem(id: "rvm:" + path, ecosystem: .ruby, kind: L("Ruby 版本"), title: name, detail: L("由 RVM 安装"),
                                 path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                 usage: context.usage(of: name, isDefault: rvmDefault?.hasSuffix(name) ?? false, wanted: wanted),
                                 removal: .trash(path),
                                 consequence: L("这个版本的 Ruby 会被移到废纸篓；需要时用 rvm install 重新安装。")))
        }
        return DevGroup(ecosystem: .ruby, items: items)
    }
}

/// Rust toolchains from rustup, and Cargo's download caches.
enum RustTools {
    static func discover(_ context: DevContext) -> DevGroup {
        var items: [DevItem] = []
        let rustup = ToolCommand("rustup", [])
        let defaultToolchain = context.output("rustup", ["default"]).flatMap(parseDefault)
            ?? parseSettings(context.home + "/.rustup/settings.toml")
        let wanted = context.projectVersions(in: ["rust-toolchain"])
            + context.filesInScan(named: "rust-toolchain.toml").compactMap(toolchainChannel)
        for path in context.subfolders(of: context.home + "/.rustup/toolchains") {
            let name = (path as NSString).lastPathComponent
            // "1.75.0-aarch64-apple-darwin" or "stable-aarch64-apple-darwin": projects name the part before the target.
            let channel = name.components(separatedBy: "-").first ?? name
            let projects = wanted.filter { $0 == channel || name.hasPrefix($0 + "-") }.count
            let usage: DevItem.Usage = name == defaultToolchain ? .active(L("当前默认"))
                : projects > 0 ? .used(L("\(projects) 个项目在用"))
                : context.tree == nil ? .unknown : .unused(L("扫描范围内没有项目指定它"))
            items.append(DevItem(id: "rustup:" + path, ecosystem: .rust, kind: L("工具链"), title: name, path: path,
                                 size: context.size(of: path), lastUsed: context.modified(path), usage: usage,
                                 removal: rustup.isInstalled ? .command(ToolCommand("rustup", ["toolchain", "uninstall", name])) : .trash(path),
                                 consequence: L("这个工具链会被删除；需要时 rustup 会重新下载。")))
        }
        for (path, title) in [(context.home + "/.cargo/registry", L("Cargo 依赖缓存")), (context.home + "/.cargo/git", L("Cargo Git 依赖"))] {
            guard let size = context.size(of: path), size > 0 else { continue }
            items.append(DevItem(id: "cargo:" + path, ecosystem: .rust, kind: L("缓存"), title: title, detail: path.abbreviatingHome,
                                 path: path, size: size, lastUsed: context.modified(path), usage: .regenerable(L("可以重新下载")),
                                 removal: .trash(path), consequence: L("下次编译时会重新下载依赖。")))
        }
        return DevGroup(ecosystem: .rust, items: items)
    }

    /// `rustup default` prints "stable-aarch64-apple-darwin (default)".
    static func parseDefault(_ output: String) -> String? {
        output.split(separator: "\n").first.flatMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// `default_toolchain = "stable-aarch64-apple-darwin"` in rustup's settings.toml.
    static func parseSettings(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let range = text.range(of: #"default_toolchain\s*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "\"").dropFirst().first.map(String.init)
    }

    /// `channel = "1.75.0"` in a project's rust-toolchain.toml.
    static func toolchainChannel(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let range = text.range(of: #"channel\s*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        return text[range].split(separator: "\"").dropFirst().first.map(String.init)
    }
}
