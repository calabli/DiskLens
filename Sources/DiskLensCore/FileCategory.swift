/// What kind of content an entry holds, used to color the treemap.
public enum FileCategory: Int, CaseIterable, Sendable {
    case folder
    case application
    case video
    case image
    case audio
    case document
    case code
    case archive
    case diskImage
    case other

    public static func of(name: String, kind: EntryKind) -> FileCategory {
        let ext = fileExtension(name)
        if kind == .directory {
            // Bundles that look like single files in Finder.
            if ext == "app" { return .application }
            if ext == "sparsebundle" { return .diskImage }
            if ext == "photoslibrary" { return .image }
            return .folder
        }
        return byExtension[ext] ?? .other
    }

    /// Bundles drawn as one block in the treemap instead of being broken into their contents.
    public var isOpaqueBundle: Bool {
        self != .folder
    }

    private static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        let groups: [(FileCategory, [String])] = [
            (.video, ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "mts", "3gp"]),
            (.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "cr2", "cr3",
                      "nef", "arw", "dng", "psd", "svg", "ico", "icns", "avif"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "ogg", "opus", "caf", "wma"]),
            (.document, ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md",
                         "rtf", "csv", "epub", "mobi"]),
            (.code, ["swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py",
                     "pyc", "rb", "go", "rs", "java", "kt", "class", "jar", "json", "yaml", "yml", "xml", "html",
                     "css", "scss", "sh", "o", "a", "dylib", "so", "wasm", "map", "lock", "sqlite", "db",
                     "pcm", "swiftmodule", "swiftinterface", "swiftdoc", "swiftsourceinfo", "d", "dia"]),
            (.archive, ["zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "zst", "lz4"]),
            (.diskImage, ["dmg", "iso", "img", "pkg", "xip", "vmdk", "qcow2", "vdi", "sparseimage", "ipsw", "raw"]),
        ]
        for (category, extensions) in groups {
            for ext in extensions { map[ext] = category }
        }
        // Camera RAW files use vendor extensions (cr2, nef, arw…); a bare ".raw" is usually a VM disk like Docker.raw.
        // "ts" is far more often TypeScript than MPEG transport stream on a developer's disk.
        map["ts"] = .code
        return map
    }()
}
