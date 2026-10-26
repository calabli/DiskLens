import CryptoKit
import Foundation

/// Rule libraries published after release. A published library is a JSON file
/// plus an Ed25519 signature over its exact bytes; it is used only if the
/// signature checks out against the key built into the app, its version is
/// newer than what the app has, and every rule passes `RuleValidator`.
public enum SignedRules {
    /// The public half of the key that signs published rules. The private half
    /// stays with whoever publishes them (see `disklens rules sign`).
    public static let publicKeyBase64 = "FnMiZuGNMrnY7zFZxn4GeRkbtoNbFmn79V+nK44IrdM="

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case badSignature
        case unreadable(String)
        case invalid([String])

        public var description: String {
            switch self {
            case .badSignature: "签名不对，规则可能被改动过"
            case let .unreadable(reason): "规则文件读不懂：\(reason)"
            case let .invalid(problems): "规则没通过检查：" + problems.prefix(3).joined(separator: "；")
            }
        }
    }

    /// Checks `signature` (base64) over `data` and the rules inside; returns them if all is well.
    public static func open(_ data: Data, signature: Data,
                            publicKey: String = publicKeyBase64) throws -> CleanupRuleSet {
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let signatureBytes = Data(base64Encoded: signature.trimmingNewlines()),
              key.isValidSignature(signatureBytes, for: data)
        else { throw Failure.badSignature }
        let set: CleanupRuleSet
        do {
            set = try CleanupRuleSet(data: data)
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
        let problems = RuleValidator.problems(in: set)
        guard problems.isEmpty else { throw Failure.invalid(problems) }
        return set
    }

    /// A base64 signature of `data`, for publishing.
    public static func sign(_ data: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        try privateKey.signature(for: data).base64EncodedString()
    }
}

/// Limits on what a rule may point at, so even a correctly signed library
/// cannot steer cleanup towards personal files.
public enum RuleValidator {
    /// Folders in the home folder that hold the user's own files.
    static let personalFolders: Set<String> = ["Desktop", "Documents", "Pictures", "Movies", "Music", "Public",
                                               "Applications", "Sites", "iCloud Drive (Archive)"]
    /// Programs a rule may suggest running; a command is only ever shown, never run by DiskLens.
    static let allowedPrograms: Set<String> = ["xcrun", "brew", "docker", "npm", "pnpm", "yarn", "bun", "pip",
                                               "pip3", "uv", "conda", "mamba", "go", "cargo", "gem", "pod",
                                               "gradle", "tmutil", "simctl"]

    public static func problems(in set: CleanupRuleSet) -> [String] {
        var problems: [String] = []
        var ids = Set<String>()
        for rule in set.rules {
            if !ids.insert(rule.id).inserted { problems.append("\(rule.id)：id 重复") }
            if rule.paths.isEmpty && rule.command == nil { problems.append("\(rule.id)：没有路径") }
            for path in rule.paths {
                if let problem = problem(withPath: path) { problems.append("\(rule.id)：\(path) \(problem)") }
            }
            if let command = rule.command {
                let program = command.split(separator: " ").first.map(String.init) ?? ""
                if !allowedPrograms.contains(program) || command.contains(where: { ";|&`$<>\n".contains($0) }) {
                    problems.append("\(rule.id)：命令不在允许范围内")
                }
            }
        }
        return problems
    }

    /// Why `path` is not allowed in a rule, or nil if it is.
    public static func problem(withPath path: String) -> String? {
        guard path.hasPrefix("~/") else { return "必须在个人文件夹里（以 ~/ 开头）" }
        let parts = path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("**") }) {
            return "含有空的、. 或 .. 的路径段"
        }
        let first = parts[0]
        if first.contains(where: { "*?[".contains($0) }) { return "第一层不能用通配符" }
        if personalFolders.contains(first) { return "指向个人文件" }
        if parts.count == 1 && path != "~/.Trash" { return "范围太大" }
        if first == "Library" && (parts.count < 3 || parts[1].contains(where: { "*?[".contains($0) })) {
            return "在资源库里范围太大"
        }
        if parts.count == 2 && parts[1] == "*" { return "会匹配整个文件夹的所有内容" }
        return nil
    }
}

/// The rule library in use: the newer of the one built into the app and the
/// last verified download, which is kept in Application Support.
public struct RuleStore: Sendable {
    public let directory: URL
    public let feed: URL

    public static let defaultFeed = URL(string: "https://calabli.github.io/DiskLens/rules/")!

    public init(directory: URL, feed: URL = RuleStore.defaultFeed) {
        self.directory = directory
        self.feed = feed
    }

    /// ~/Library/Application Support/<bundle id>/Rules.
    public static var standard: RuleStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "app.disklens.DiskLens"
        return RuleStore(directory: support.appendingPathComponent(id).appendingPathComponent("Rules"))
    }

    private var rulesFile: URL { directory.appendingPathComponent("cleanup-rules.json") }
    private var signatureFile: URL { directory.appendingPathComponent("cleanup-rules.json.sig") }

    /// The downloaded library, checked again on every load; nil if there is none or it fails the checks.
    public func downloaded(publicKey: String = SignedRules.publicKeyBase64) -> CleanupRuleSet? {
        guard let data = try? Data(contentsOf: rulesFile),
              let signature = try? Data(contentsOf: signatureFile) else { return nil }
        return try? SignedRules.open(data, signature: signature, publicKey: publicKey)
    }

    /// The library to use now.
    public func current(bundled: CleanupRuleSet, publicKey: String = SignedRules.publicKeyBase64) -> CleanupRuleSet {
        guard let downloaded = downloaded(publicKey: publicKey), downloaded.version > bundled.version else {
            return bundled
        }
        return downloaded
    }

    public enum Outcome: Sendable, Equatable {
        case updated(version: Int)
        case upToDate(version: Int)
    }

    /// Downloads the published library and keeps it if it is newer than `installed` and passes the checks.
    /// Nothing about this Mac is sent; it is two plain downloads.
    public func update(installed: Int, publicKey: String = SignedRules.publicKeyBase64,
                       session: URLSession = .shared) async throws -> (Outcome, CleanupRuleSet?) {
        let (data, signature) = try await (
            download(feed.appendingPathComponent("cleanup-rules.json"), session: session),
            download(feed.appendingPathComponent("cleanup-rules.json.sig"), session: session))
        let set = try SignedRules.open(data, signature: signature, publicKey: publicKey)
        guard set.version > installed else { return (.upToDate(version: installed), nil) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: rulesFile, options: .atomic)
        try signature.write(to: signatureFile, options: .atomic)
        return (.updated(version: set.version), set)
    }

    private func download(_ url: URL, session: URLSession) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await session.data(for: request)
        // A file feed (used in tests) has no status code.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

private extension Data {
    func trimmingNewlines() -> Data {
        Data(String(decoding: self, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
