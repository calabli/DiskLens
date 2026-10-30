import CryptoKit
import Foundation

/// A newer DiskLens published on GitHub Releases.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let tag: String
    public let title: String
    /// The release notes, in Markdown.
    public let notes: String
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let archiveURL: URL
    public let archiveSize: Int64
    /// Ed25519 signature of the archive, made with the same key as the cleanup rules.
    public let signatureURL: URL
    public let pageURL: URL?
}

/// Finds updates on GitHub Releases and downloads them, checking every
/// archive against the signing key built into the app before using it.
public enum SoftwareUpdate {
    /// GitHub's release list; DISKLENS_UPDATE_FEED points it at a local copy for testing.
    public static var releasesAPI: URL {
        ProcessInfo.processInfo.environment["DISKLENS_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/calabli/DiskLens/releases?per_page=20")!
    }

    /// "0.10.2" > "0.9", component by component; a leading "v" is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (v: String) in
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest release in GitHub's release list that is newer than `current` and carries
    /// both a `DiskLens-<version>.zip` and its `.sig`. Drafts are skipped; pre-releases count
    /// only when `includePrereleases` is on.
    public static func newest(in releasesJSON: Data, newerThan current: String,
                              includePrereleases: Bool = true) -> AvailableUpdate? {
        guard let releases = try? JSONSerialization.jsonObject(with: releasesJSON) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let updates = releases.compactMap { release -> AvailableUpdate? in
            guard release["draft"] as? Bool != true,
                  let tag = release["tag_name"] as? String else { return nil }
            let prerelease = release["prerelease"] as? Bool ?? false
            guard includePrereleases || !prerelease else { return nil }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard isNewer(version, than: current) else { return nil }
            let assets = (release["assets"] as? [[String: Any]]) ?? []
            let archiveName = "DiskLens-\(version).zip"
            guard let archive = assets.first(where: { $0["name"] as? String == archiveName }),
                  let signature = assets.first(where: { $0["name"] as? String == archiveName + ".sig" }),
                  let archiveURL = (archive["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  let signatureURL = (signature["browser_download_url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            return AvailableUpdate(version: version, tag: tag, title: release["name"] as? String ?? tag,
                                   notes: release["body"] as? String ?? "",
                                   publishedAt: (release["published_at"] as? String).flatMap(iso.date(from:)),
                                   isPrerelease: prerelease, archiveURL: archiveURL,
                                   archiveSize: (archive["size"] as? NSNumber)?.int64Value ?? 0,
                                   signatureURL: signatureURL,
                                   pageURL: (release["html_url"] as? String).flatMap(URL.init(string:)))
        }
        return updates.max { isNewer($1.version, than: $0.version) }
    }

    /// Asks GitHub for the newest release newer than `current`. Sends nothing about this Mac.
    public static func check(current: String, includePrereleases: Bool = true,
                             session: URLSession = .shared) async throws -> AvailableUpdate? {
        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return newest(in: data, newerThan: current, includePrereleases: includePrereleases)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case badSignature
        case notAnUpdate(String)
        case unpackFailed

        public var description: String {
            switch self {
            case .badSignature: "下载的安装包签名不对，可能被改动过，已经丢弃"
            case let .notAnUpdate(reason): "下载的不是可用的 DiskLens：\(reason)"
            case .unpackFailed: "安装包没能解压"
            }
        }
    }

    /// Downloads the update, checks its signature, unpacks it into `folder` and checks the app
    /// inside is DiskLens at the promised version. Returns the unpacked app.
    public static func download(_ update: AvailableUpdate, into folder: URL, publicKey: String = SignedRules.publicKeyBase64,
                                session: URLSession = .shared,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let (archiveFile, _) = try await session.download(from: update.archiveURL, delegate: progress.map(ProgressDelegate.init))
        let archive = try Data(contentsOf: archiveFile)
        let (signature, _) = try await session.data(from: update.signatureURL)
        return try unpack(archive, signature: signature, expectedVersion: update.version, into: folder, publicKey: publicKey)
    }

    /// The checks and unpacking of `download`, on bytes already in hand.
    static func unpack(_ archive: Data, signature: Data, expectedVersion: String, into folder: URL,
                       publicKey: String) throws -> URL {
        guard verify(archive, signature: signature, publicKey: publicKey) else { throw Failure.badSignature }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("update.zip")
        try archive.write(to: zip)
        let unpack = try ToolCommand("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]).run(timeout: 120)
        try? fm.removeItem(at: zip)
        guard unpack.succeeded else { throw Failure.unpackFailed }
        let app = folder.appendingPathComponent("DiskLens.app")
        guard let bundle = Bundle(url: app) else { throw Failure.notAnUpdate("找不到 DiskLens.app") }
        guard bundle.bundleIdentifier == "app.disklens.DiskLens" else { throw Failure.notAnUpdate("标识符不对") }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard version == expectedVersion else { throw Failure.notAnUpdate("版本是 \(version)，应为 \(expectedVersion)") }
        return app
    }

    static func verify(_ data: Data, signature: Data, publicKey: String) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let signatureBytes = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(signatureBytes, for: data)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void

        init(_ report: @escaping @Sendable (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
