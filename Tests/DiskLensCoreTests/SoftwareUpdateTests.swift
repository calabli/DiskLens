import CryptoKit
import Foundation
import Testing
@testable import DiskLensCore

@Test func versionsCompareComponentByComponent() {
    #expect(SoftwareUpdate.isNewer("0.10.0", than: "0.9.3"))
    #expect(SoftwareUpdate.isNewer("v0.2", than: "0.1.9"))
    #expect(SoftwareUpdate.isNewer("1.0.1", than: "1.0"))
    #expect(!SoftwareUpdate.isNewer("0.1.0", than: "0.1.0"))
    #expect(!SoftwareUpdate.isNewer("0.1", than: "0.1.0"))
}

private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, signed: Bool = true) -> [String: Any] {
    let version = tag.dropFirst()
    var assets: [[String: Any]] = [["name": "DiskLens-\(version).zip", "size": 4_500_000,
                                    "browser_download_url": "https://example.com/DiskLens-\(version).zip"]]
    if signed { assets.append(["name": "DiskLens-\(version).zip.sig", "browser_download_url": "https://example.com/DiskLens-\(version).zip.sig"]) }
    return ["tag_name": tag, "name": "DiskLens \(version)", "body": "notes", "draft": draft, "prerelease": prerelease,
            "published_at": "2026-10-31T00:00:00Z", "assets": assets]
}

@Test func theNewestSignedReleaseIsOffered() throws {
    let json = try JSONSerialization.data(withJSONObject: [
        release("v0.4.0", draft: true), release("v0.3.0", signed: false), release("v0.2.1", prerelease: true),
        release("v0.2.0"), release("v0.1.0"),
    ])
    let update = try #require(SoftwareUpdate.newest(in: json, newerThan: "0.1.0"))
    #expect(update.version == "0.2.1" && update.isPrerelease)  // drafts and unsigned releases are skipped
    #expect(SoftwareUpdate.newest(in: json, newerThan: "0.1.0", includePrereleases: false)?.version == "0.2.0")
    #expect(SoftwareUpdate.newest(in: json, newerThan: "0.2.1") == nil)
}

@Test func onlyASignedArchiveOfTheRightVersionIsUnpacked() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-update-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    // A stand-in DiskLens.app, zipped the way releases are.
    let app = root.appendingPathComponent("build/DiskLens.app/Contents")
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    try (["CFBundleIdentifier": "app.disklens.DiskLens", "CFBundleShortVersionString": "0.2.0"] as NSDictionary)
        .write(to: app.appendingPathComponent("Info.plist"))
    let zip = root.appendingPathComponent("DiskLens-0.2.0.zip")
    #expect(try ToolCommand("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path + "/build/DiskLens.app", zip.path]).run().succeeded)
    let archive = try Data(contentsOf: zip)

    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let signature = Data(try SignedRules.sign(archive, privateKey: key).utf8)

    let unpacked = try SoftwareUpdate.unpack(archive, signature: signature, expectedVersion: "0.2.0",
                                             into: root.appendingPathComponent("a"), publicKey: publicKey)
    #expect(unpacked.lastPathComponent == "DiskLens.app" && fm.fileExists(atPath: unpacked.path + "/Contents/Info.plist"))

    var tampered = archive
    tampered[tampered.count / 2] ^= 1
    #expect(throws: SoftwareUpdate.Failure.badSignature) {
        try SoftwareUpdate.unpack(tampered, signature: signature, expectedVersion: "0.2.0",
                                  into: root.appendingPathComponent("b"), publicKey: publicKey)
    }
    #expect(throws: SoftwareUpdate.Failure.self) {
        try SoftwareUpdate.unpack(archive, signature: signature, expectedVersion: "0.3.0",
                                  into: root.appendingPathComponent("c"), publicKey: publicKey)
    }
}

@Test func aFeedThatFailsFallsBackToTheNext() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-feeds-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let broken = folder.appendingPathComponent("broken.json")
    try Data(#"{"message":"API rate limit exceeded"}"#.utf8).write(to: broken)
    let good = folder.appendingPathComponent("releases.json")
    try JSONSerialization.data(withJSONObject: [release("v0.3.0")]).write(to: good)
    let missing = folder.appendingPathComponent("missing.json")

    let update = try await SoftwareUpdate.check(current: "0.2.3", includePrereleases: true,
                                                feeds: [missing, broken, good], session: .shared)
    #expect(update?.version == "0.3.0")
    await #expect(throws: (any Error).self) {
        try await SoftwareUpdate.check(current: "0.2.3", includePrereleases: true, feeds: [missing, broken], session: .shared)
    }
}
