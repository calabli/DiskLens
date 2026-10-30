import Foundation

/// Docker's disk image, and when Docker is running, its images, stopped containers and build cache.
enum DockerTools {
    static func discover(_ context: DevContext) -> DevGroup {
        var items: [DevItem] = []
        let raw = context.home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        if let size = context.size(of: raw) {
            items.append(DevItem(id: "docker:raw", ecosystem: .docker, kind: "磁盘映像", title: "Docker.raw",
                                 detail: "Docker 的虚拟磁盘，镜像和容器都存在里面", path: raw, size: size,
                                 lastUsed: context.modified(raw), usage: .active("Docker 的全部数据"),
                                 removal: .none("删除镜像后它不会自动变小；可以在 Docker 设置里调整磁盘上限"),
                                 consequence: ""))
        }
        guard ToolCommand("docker", []).isInstalled else {
            return DevGroup(ecosystem: .docker, items: items, note: items.isEmpty ? "没有安装 Docker。" : nil)
        }
        guard context.output("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 10) != nil else {
            return DevGroup(ecosystem: .docker, items: items, note: "Docker 没在运行。启动 Docker 后，可以按镜像查看和清理。")
        }

        let inUse = Set((context.output("docker", ["ps", "-a", "--format", "{{.Image}}"]) ?? "")
            .split(separator: "\n").map(String.init))
        let images = parseImages(context.output("docker", ["images", "--format", "{{json .}}"]) ?? "")
        for image in images {
            let used = inUse.contains(image.reference) || inUse.contains(image.id) || inUse.contains { $0.hasPrefix(image.id) }
            items.append(DevItem(id: "docker:image:" + image.id, ecosystem: .docker, kind: "镜像",
                                 title: image.reference, detail: image.created, size: image.size,
                                 usage: used ? .active("有容器在用") : (image.isDangling ? .unused("没有名字的旧镜像") : .unknown),
                                 removal: .command(ToolCommand("docker", ["image", "rm", image.id])),
                                 consequence: "这个镜像会被删除，再用到时需要重新拉取或构建。"))
        }
        for row in parseSystemDF(context.output("docker", ["system", "df", "--format", "{{json .}}"]) ?? "") {
            switch row.type {
            case "Containers" where row.reclaimable > 0:
                items.append(DevItem(id: "docker:containers", ecosystem: .docker, kind: "容器", title: "已停止的容器",
                                     detail: "共 \(row.count) 个容器", size: row.reclaimable,
                                     usage: .unused("已经停止"),
                                     removal: .command(ToolCommand("docker", ["container", "prune", "-f"])),
                                     consequence: "所有已停止的容器会被删除，容器里没有存到数据卷的改动会丢失。"))
            case "Build Cache" where row.reclaimable > 0:
                items.append(DevItem(id: "docker:buildcache", ecosystem: .docker, kind: "构建缓存", title: "构建缓存",
                                     size: row.reclaimable, usage: .regenerable("可以重新生成"),
                                     removal: .command(ToolCommand("docker", ["builder", "prune", "-f"])),
                                     consequence: "下次构建镜像时会从头构建，第一次会慢一些。"))
            default:
                break
            }
        }
        return DevGroup(ecosystem: .docker, items: items,
                        note: "删除镜像和容器后，Docker.raw 不会自动变小，空出的空间留给 Docker 以后使用。")
    }

    struct Image: Equatable {
        let id: String
        let repository: String
        let tag: String
        let size: Int64?
        let created: String?

        var isDangling: Bool { repository == "<none>" }
        var reference: String { isDangling ? id : "\(repository):\(tag)" }
    }

    /// `docker images --format '{{json .}}'`: one JSON object per line.
    static func parseImages(_ text: String) -> [Image] {
        text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["ID"] as? String else { return nil }
            return Image(id: id, repository: object["Repository"] as? String ?? "<none>",
                         tag: object["Tag"] as? String ?? "<none>",
                         size: (object["Size"] as? String).flatMap(DevEnvironmentScanner.parseSize),
                         created: object["CreatedSince"] as? String)
        }
    }

    struct UsageRow: Equatable {
        let type: String
        let count: Int
        let size: Int64
        let reclaimable: Int64
    }

    /// `docker system df --format '{{json .}}'`, e.g. Reclaimable "1.2GB (40%)".
    static func parseSystemDF(_ text: String) -> [UsageRow] {
        text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["Type"] as? String else { return nil }
            let reclaimable = (object["Reclaimable"] as? String)?.split(separator: " ").first.map(String.init) ?? "0B"
            return UsageRow(type: type, count: Int(object["TotalCount"] as? String ?? "") ?? 0,
                            size: DevEnvironmentScanner.parseSize(object["Size"] as? String ?? "") ?? 0,
                            reclaimable: DevEnvironmentScanner.parseSize(reclaimable) ?? 0)
        }
    }
}
