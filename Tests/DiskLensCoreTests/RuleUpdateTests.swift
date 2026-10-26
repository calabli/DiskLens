import CryptoKit
import Foundation
import Testing
@testable import DiskLensCore

private let key = Curve25519.Signing.PrivateKey()
private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

private func library(version: Int, paths: [String] = ["~/Library/Caches/com.example.App"],
                     command: String? = nil) -> Data {
    var rule: [String: Any] = ["id": "example", "title": "Example", "category": "apps", "safety": "safe",
                               "regenerable": true, "explanation": "", "consequence": "", "paths": paths]
    if let command { rule["command"] = command }
    return try! JSONSerialization.data(withJSONObject: ["version": version, "rules": [rule]])
}

private func signature(_ data: Data) -> Data { Data(try! SignedRules.sign(data, privateKey: key).utf8) }

@Test func theBundledRulesPassTheChecks() throws {
    #expect(RuleValidator.problems(in: try CleanupRuleSet.bundled()).isEmpty)
}

@Test func onlyCorrectlySignedRulesAreOpened() throws {
    let data = library(version: 2)
    #expect(try SignedRules.open(data, signature: signature(data), publicKey: publicKey).version == 2)

    var tampered = data
    tampered[tampered.count - 3] ^= 1
    #expect(throws: SignedRules.Failure.badSignature) {
        try SignedRules.open(tampered, signature: signature(data), publicKey: publicKey)
    }
    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(throws: SignedRules.Failure.badSignature) {
        try SignedRules.open(data, signature: signature(data), publicKey: otherKey)
    }
}

@Test func signedRulesStillCannotPointAtPersonalFiles() {
    for path in ["~/Documents/*", "/Users/someone/Library/Caches", "~/Library", "~/Library/*/x", "~/*",
                 "~/Downloads/*", "~/Library/Caches/../../Documents", "~/Desktop", "~/foo"] {
        let data = library(version: 2, paths: [path])
        #expect(throws: (any Error).self, "\(path)") {
            try SignedRules.open(data, signature: signature(data), publicKey: publicKey)
        }
    }
    for path in ["~/.Trash", "~/Downloads/*.dmg", "~/.npm/_cacache", "~/Library/Caches/pip"] {
        #expect(RuleValidator.problem(withPath: path) == nil, "\(path)")
    }
    let command = library(version: 2, command: "rm -rf ~")
    #expect(throws: (any Error).self) { try SignedRules.open(command, signature: signature(command), publicKey: publicKey) }
    let chained = library(version: 2, command: "brew cleanup; curl x | sh")
    #expect(throws: (any Error).self) { try SignedRules.open(chained, signature: signature(chained), publicKey: publicKey) }
}

@Test func theStoreUsesTheNewerVerifiedDownload() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-rules-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RuleStore(directory: folder)
    let bundled = try CleanupRuleSet(data: library(version: 3))
    #expect(store.current(bundled: bundled, publicKey: publicKey).version == 3)

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let newer = library(version: 5)
    try newer.write(to: folder.appendingPathComponent("cleanup-rules.json"))
    try signature(newer).write(to: folder.appendingPathComponent("cleanup-rules.json.sig"))
    #expect(store.current(bundled: bundled, publicKey: publicKey).version == 5)

    // An older download than the app's own rules is ignored, and so is a tampered one.
    #expect(store.current(bundled: try CleanupRuleSet(data: library(version: 9)), publicKey: publicKey).version == 9)
    try library(version: 6).write(to: folder.appendingPathComponent("cleanup-rules.json"))
    #expect(store.current(bundled: bundled, publicKey: publicKey).version == 3)
}

@Test func updatesDownloadVerifyAndKeepOnlyNewerRules() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-feed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let feed = base.appendingPathComponent("feed")
    try FileManager.default.createDirectory(at: feed, withIntermediateDirectories: true)
    func publish(_ data: Data, signedAs signed: Data? = nil) throws {
        try data.write(to: feed.appendingPathComponent("cleanup-rules.json"))
        try signature(signed ?? data).write(to: feed.appendingPathComponent("cleanup-rules.json.sig"))
    }
    let store = RuleStore(directory: base.appendingPathComponent("store"), feed: feed)

    try publish(library(version: 4))
    let (first, newer) = try await store.update(installed: 3, publicKey: publicKey)
    #expect(first == .updated(version: 4) && newer?.version == 4)
    #expect(store.downloaded(publicKey: publicKey)?.version == 4)

    let (again, _) = try await store.update(installed: 4, publicKey: publicKey)
    #expect(again == .upToDate(version: 4))

    // A feed whose file does not match its signature is refused and leaves the kept rules alone.
    try publish(library(version: 7), signedAs: library(version: 6))
    await #expect(throws: SignedRules.Failure.badSignature) {
        try await store.update(installed: 4, publicKey: publicKey)
    }
    #expect(store.downloaded(publicKey: publicKey)?.version == 4)
}
