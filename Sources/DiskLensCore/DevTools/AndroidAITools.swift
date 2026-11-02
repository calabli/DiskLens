import Foundation

/// The Android SDK's system images, platforms and build tools, and emulators.
enum AndroidTools {
    static func discover(_ context: DevContext) -> DevGroup {
        let sdk = [ProcessInfo.processInfo.environment["ANDROID_HOME"], context.home + "/Library/Android/sdk"]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
        var items: [DevItem] = []
        let avds = emulators(context)
        let usedImages = Set(avds.compactMap(\.image))

        for avd in avds {
            let avdmanager = sdk.map { $0 + "/cmdline-tools/latest/bin/avdmanager" }
                .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            items.append(DevItem(id: "avd:" + avd.path, ecosystem: .android, kind: "模拟器", title: avd.name,
                                 detail: avd.image.map { $0.replacingOccurrences(of: "system-images/", with: "") },
                                 path: avd.path, size: context.size(of: avd.path), lastUsed: context.modified(avd.path),
                                 removal: avdmanager.map { .command(ToolCommand($0, ["delete", "avd", "-n", avd.name])) } ?? .trash(avd.path),
                                 consequence: "这台模拟器和里面的应用、数据会被删除；需要时可以在 Android Studio 里重新创建。"))
        }
        guard let sdk else {
            return DevGroup(ecosystem: .android, items: items)
        }
        // system-images/android-34/google_apis/arm64-v8a
        for api in context.subfolders(of: sdk + "/system-images") {
            for tag in context.subfolders(of: api) {
                for abi in context.subfolders(of: tag) {
                    let relative = String(abi.dropFirst(sdk.count + 1))
                    let users = usedImages.filter { $0.hasPrefix(relative) }.count
                    items.append(DevItem(id: "sysimg:" + abi, ecosystem: .android, kind: "系统映像",
                                         title: relative.replacingOccurrences(of: "system-images/", with: ""),
                                         path: abi, size: context.size(of: abi), lastUsed: context.modified(abi),
                                         usage: users > 0 ? .used("\(users) 台模拟器在用") : .unused("没有模拟器在用"),
                                         removal: .trash(abi),
                                         consequence: "用这个系统映像的模拟器将无法启动；需要时可以在 SDK Manager 里重新下载。"))
                }
            }
        }
        // Old build tools: everything but the newest version is kept only for old projects.
        let buildTools = context.subfolders(of: sdk + "/build-tools")
        let newest = buildTools.map { ($0 as NSString).lastPathComponent }.max { SoftwareUpdate.isNewer($1, than: $0) }
        for path in buildTools {
            let version = (path as NSString).lastPathComponent
            items.append(DevItem(id: "buildtools:" + path, ecosystem: .android, kind: "构建工具", title: "Build Tools \(version)",
                                 path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                 usage: version == newest ? .used("最新版本") : .unknown,
                                 removal: .trash(path),
                                 consequence: "指定这个版本的项目构建时会重新下载它。"))
        }
        for path in context.subfolders(of: sdk + "/platforms") {
            items.append(DevItem(id: "platform:" + path, ecosystem: .android, kind: "SDK 平台",
                                 title: (path as NSString).lastPathComponent, path: path, size: context.size(of: path),
                                 lastUsed: context.modified(path), removal: .trash(path),
                                 consequence: "以这个 API 版本编译的项目构建时会重新下载它。"))
        }
        return DevGroup(ecosystem: .android, items: items)
    }

    struct Emulator: Equatable {
        let name: String
        let path: String
        /// "system-images/android-34/google_apis/arm64-v8a/", from its config.ini.
        let image: String?
    }

    private static func emulators(_ context: DevContext) -> [Emulator] {
        let folder = context.home + "/.android/avd"
        return context.subfolders(of: folder).filter { $0.hasSuffix(".avd") }.map { path in
            let name = String((path as NSString).lastPathComponent.dropLast(".avd".count))
            let config = (try? String(contentsOfFile: path + "/config.ini", encoding: .utf8)) ?? ""
            return Emulator(name: name, path: path, image: systemImage(fromConfig: config))
        }
    }

    /// `image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/` in an emulator's config.ini.
    static func systemImage(fromConfig text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("image.sysdir.1") }
            .flatMap { $0.split(separator: "=", maxSplits: 1).last }
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/") }
    }
}

/// Downloaded AI models: Ollama, Hugging Face and LM Studio.
enum ModelTools {
    static func discover(_ context: DevContext) -> DevGroup {
        var items: [DevItem] = []
        items += ollama(context)

        let hub = ProcessInfo.processInfo.environment["HF_HOME"].map { $0 + "/hub" } ?? context.home + "/.cache/huggingface/hub"
        for path in context.subfolders(of: hub) {
            let folder = (path as NSString).lastPathComponent
            guard let (kind, name) = huggingFaceName(folder) else { continue }
            items.append(DevItem(id: "hf:" + path, ecosystem: .ai, kind: kind, title: name, detail: "Hugging Face 缓存",
                                 path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                 removal: .trash(path),
                                 consequence: "下次用到这个模型时会重新下载，大模型可能要很久。"))
        }

        for base in [context.home + "/.lmstudio/models", context.home + "/.cache/lm-studio/models"] {
            for publisher in context.subfolders(of: base) {
                for path in context.subfolders(of: publisher) {
                    let name = (publisher as NSString).lastPathComponent + "/" + (path as NSString).lastPathComponent
                    items.append(DevItem(id: "lmstudio:" + path, ecosystem: .ai, kind: "模型", title: name, detail: "LM Studio",
                                         path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                         removal: .trash(path),
                                         consequence: "这个模型会被移到废纸篓；需要时在 LM Studio 里重新下载。"))
                }
            }
        }
        return DevGroup(ecosystem: .ai, items: items)
    }

    /// "models--meta-llama--Llama-3.1-8B" → ("模型", "meta-llama/Llama-3.1-8B").
    static func huggingFaceName(_ folder: String) -> (String, String)? {
        let parts = folder.components(separatedBy: "--")
        guard parts.count >= 2 else { return nil }
        let kind = switch parts[0] {
        case "models": "模型"
        case "datasets": "数据集"
        case "spaces": "Space"
        default: ""
        }
        return kind.isEmpty ? nil : (kind, parts.dropFirst().joined(separator: "/"))
    }

    struct OllamaModel: Equatable {
        let name: String
        let size: Int64
        let layers: [String]
    }

    /// Ollama keeps a manifest per model (manifests/registry.ollama.ai/library/llama3/8b)
    /// listing the blobs it is made of; blobs shared between models are stored once.
    private static func ollama(_ context: DevContext) -> [DevItem] {
        let base = ProcessInfo.processInfo.environment["OLLAMA_MODELS"] ?? context.home + "/.ollama/models"
        let manifests = base + "/manifests"
        guard let enumerator = FileManager.default.enumerator(atPath: manifests) else { return [] }
        var models: [(OllamaModel, String)] = []
        for case let relative as String in enumerator {
            let path = manifests + "/" + relative
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                  let data = FileManager.default.contents(atPath: path),
                  let model = parseOllamaManifest(data, relativePath: relative) else { continue }
            models.append((model, path))
        }
        let useCount = models.flatMap(\.0.layers).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let hasOllama = ToolCommand("ollama", []).isInstalled
        return models.map { model, path in
            let shared = model.layers.filter { (useCount[$0] ?? 0) > 1 }.count
            return DevItem(id: "ollama:" + path, ecosystem: .ai, kind: "模型", title: model.name,
                           detail: "Ollama" + (shared > 0 ? " · 部分数据与其他模型共用" : ""), path: path,
                           size: model.size, lastUsed: context.modified(path),
                           removal: hasOllama ? .command(ToolCommand("ollama", ["rm", model.name])) : .none("用 ollama rm 删除"),
                           consequence: "这个模型会被删除；需要时用 ollama pull 重新下载。")
        }
    }

    /// A manifest at "registry.ollama.ai/library/llama3/8b" names "llama3:8b"; other registries keep their path.
    static func parseOllamaManifest(_ data: Data, relativePath: String) -> OllamaModel? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = json["layers"] as? [[String: Any]] else { return nil }
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        let tag = parts[parts.count - 1], model = parts[parts.count - 2]
        let namespace = parts.count >= 4 ? parts[parts.count - 3] : ""
        let registry = parts.first ?? ""
        let name = registry == "registry.ollama.ai" && namespace == "library" ? "\(model):\(tag)"
            : registry == "registry.ollama.ai" ? "\(namespace)/\(model):\(tag)"
            : "\(parts.dropLast().joined(separator: "/")):\(tag)"
        let all = layers + [json["config"] as? [String: Any]].compactMap { $0 }
        let size = all.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
        return OllamaModel(name: name, size: size, layers: all.compactMap { $0["digest"] as? String })
    }
}
