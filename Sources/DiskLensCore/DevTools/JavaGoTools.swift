import Foundation

/// JDKs, Gradle distributions and caches, and the Maven repository.
enum JavaTools {
    static func discover(_ context: DevContext) -> DevGroup {
        var items: [DevItem] = []
        let listing = context.run(ToolCommand("/usr/libexec/java_home", ["-V"]), 10)
        let jdks = parseJavaHomes((listing?.errors ?? "") + (listing?.output ?? ""))
        let current = context.output("/usr/libexec/java_home", [])?.trimmingCharacters(in: .whitespacesAndNewlines)
        for jdk in jdks {
            // ".../zulu-8.jdk/Contents/Home" → the .jdk bundle.
            let bundle = jdk.home.components(separatedBy: "/Contents/Home").first ?? jdk.home
            items.append(DevItem(id: "jdk:" + bundle, ecosystem: .java, kind: "JDK", title: jdk.name,
                                 detail: "版本 \(jdk.version) · \(jdk.vendor)", path: bundle, size: context.size(of: bundle),
                                 usage: jdk.home == current ? .active("当前默认") : .unknown,
                                 removal: .trash(bundle),
                                 consequence: "这个 JDK 会被移到废纸篓；指定用它的项目和工具需要改用其他版本。"))
        }

        let wanted = gradleVersionsInProjects(context)
        let dists = context.home + "/.gradle/wrapper/dists"
        for path in context.subfolders(of: dists) {
            let folder = (path as NSString).lastPathComponent
            let version = gradleVersion(fromFolder: folder) ?? folder
            let projects = wanted[version] ?? 0
            items.append(DevItem(id: "gradle:" + path, ecosystem: .java, kind: "Gradle", title: "Gradle \(version)",
                                 detail: folder, path: path, size: context.size(of: path), lastUsed: context.modified(path),
                                 usage: projects > 0 ? .used("\(projects) 个项目在用") : (context.tree == nil ? .unknown : .unused("扫描范围内没有项目在用")),
                                 removal: .trash(path),
                                 consequence: "用这个版本的项目下次构建时会重新下载它，约 100–200 MB。"))
        }
        for (path, title, consequence) in [
            (context.home + "/.gradle/caches", "Gradle 缓存", "依赖和构建缓存会在下次构建时重新下载，第一次会慢很多。"),
            (context.home + "/.m2/repository", "Maven 本地仓库", "依赖会在下次构建时重新下载。"),
        ] {
            guard let size = context.size(of: path), size > 0 else { continue }
            items.append(DevItem(id: "java:" + path, ecosystem: .java, kind: "缓存", title: title, detail: path.abbreviatingHome,
                                 path: path, size: size, lastUsed: context.modified(path), usage: .regenerable("可以重新下载"),
                                 removal: .trash(path), consequence: consequence))
        }
        return DevGroup(ecosystem: .java, items: items, note: items.isEmpty ? "没有找到 JDK、Gradle 或 Maven 的数据。" : nil)
    }

    struct JavaHome: Equatable {
        let version: String
        let vendor: String
        let name: String
        let home: String
    }

    /// `/usr/libexec/java_home -V` lines such as
    /// `    21 (arm64) "Oracle Corporation" - "Java SE 21" /Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home`.
    static func parseJavaHomes(_ text: String) -> [JavaHome] {
        let pattern = #"^\s+(\S+)\s+\([^)]*\)\s+"([^"]*)"\s+-\s+"([^"]*)"\s+(/.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            JavaHome(version: ns.substring(with: m.range(at: 1)), vendor: ns.substring(with: m.range(at: 2)),
                     name: ns.substring(with: m.range(at: 3)), home: ns.substring(with: m.range(at: 4)))
        }
    }

    /// "gradle-8.5-bin" or "gradle-8.10.2-all" → "8.10.2".
    static func gradleVersion(fromFolder name: String) -> String? {
        guard name.hasPrefix("gradle-") else { return nil }
        var rest = name.dropFirst("gradle-".count)
        for suffix in ["-bin", "-all"] where rest.hasSuffix(suffix) { rest = rest.dropLast(suffix.count) }
        return String(rest)
    }

    /// "distributionUrl=https\://services.gradle.org/distributions/gradle-8.5-bin.zip" → "8.5".
    static func gradleVersion(fromWrapperProperties text: String) -> String? {
        guard let range = text.range(of: #"gradle-[0-9][^/\s]*?-(bin|all)\.zip"#, options: .regularExpression) else { return nil }
        return gradleVersion(fromFolder: String(text[range].dropLast(".zip".count)))
    }

    /// How many scanned projects ask for each Gradle version, from their wrapper settings.
    private static func gradleVersionsInProjects(_ context: DevContext) -> [String: Int] {
        var counts: [String: Int] = [:]
        for path in context.filesInScan(named: "gradle-wrapper.properties") where !path.contains("/.gradle/") {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let version = gradleVersion(fromWrapperProperties: text) else { continue }
            counts[version, default: 0] += 1
        }
        return counts
    }
}

/// Go's module cache and build cache.
enum GoTools {
    static func discover(_ context: DevContext) -> DevGroup {
        let hasGo = ToolCommand("go", []).isInstalled
        let modCache = context.output("go", ["env", "GOMODCACHE"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? context.home + "/go/pkg/mod"
        let buildCache = context.output("go", ["env", "GOCACHE"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? context.home + "/Library/Caches/go-build"
        var items: [DevItem] = []
        if let size = context.size(of: modCache), size > 0 {
            items.append(DevItem(id: "go:mod", ecosystem: .go, kind: "模块缓存", title: "模块缓存", detail: modCache.abbreviatingHome,
                                 path: modCache, size: size, lastUsed: context.modified(modCache), usage: .regenerable("可以重新下载"),
                                 removal: hasGo ? .command(ToolCommand("go", ["clean", "-modcache"])) : .trash(modCache),
                                 consequence: "下载过的依赖模块和自动下载的 Go 工具链都会删除，下次构建时重新下载。"))
        }
        if let size = context.size(of: buildCache), size > 0 {
            items.append(DevItem(id: "go:build", ecosystem: .go, kind: "构建缓存", title: "构建缓存", detail: buildCache.abbreviatingHome,
                                 path: buildCache, size: size, lastUsed: context.modified(buildCache), usage: .regenerable("可以重新生成"),
                                 removal: hasGo ? .command(ToolCommand("go", ["clean", "-cache"])) : .trash(buildCache),
                                 consequence: "下次编译会重新生成，第一次会慢一些。"))
        }
        return DevGroup(ecosystem: .go, items: items, note: items.isEmpty ? "没有找到 Go 的数据。" : nil)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
