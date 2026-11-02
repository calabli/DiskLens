import Foundation
import Testing
@testable import DiskLensCore

@Test func projectVersionsMatchInstalledVersions() {
    #expect(DevContext.version("18", matches: "v18.19.0"))
    #expect(DevContext.version("v20.11", matches: "v20.11.0"))
    #expect(DevContext.version("3.11", matches: "3.11.6"))
    #expect(DevContext.version("ruby-3.2.2", matches: "3.2.2"))
    #expect(!DevContext.version("3.1", matches: "3.11.6"))
    #expect(!DevContext.version("20.11.0.1", matches: "20.11.0"))
}

@Test func modelAndToolNamesAreRead() throws {
    #expect(ModelTools.huggingFaceName("models--meta-llama--Llama-3.1-8B")! == ("模型", "meta-llama/Llama-3.1-8B"))
    #expect(ModelTools.huggingFaceName("datasets--squad")! == ("数据集", "squad"))
    #expect(ModelTools.huggingFaceName(".locks") == nil)

    let manifest = Data(#"{"config":{"digest":"sha256:c","size":500},"layers":[{"digest":"sha256:a","size":4000000000},{"digest":"sha256:b","size":12000}]}"#.utf8)
    let llama = try #require(ModelTools.parseOllamaManifest(manifest, relativePath: "registry.ollama.ai/library/llama3/8b"))
    #expect(llama.name == "llama3:8b" && llama.size == 4_000_012_500 && llama.layers.count == 3)
    #expect(ModelTools.parseOllamaManifest(manifest, relativePath: "registry.ollama.ai/someone/coder/latest")?.name == "someone/coder:latest")

    #expect(AndroidTools.systemImage(fromConfig: "hw.ramSize=2048\nimage.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\n")
            == "system-images/android-34/google_apis/arm64-v8a/")
    #expect(RustTools.parseDefault("stable-aarch64-apple-darwin (default)\n") == "stable-aarch64-apple-darwin")
}

/// A home folder with a bit of everything, scanned like a real one.
@Test func versionManagersSDKsAndModelsAreFoundAndJudged() throws {
    let home = NSTemporaryDirectory() + "disklens-devhome-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: home) }
    func file(_ relative: String, _ text: String = "x") throws {
        let path = home + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    try file(".nvm/versions/node/v18.19.0/bin/node"); try file(".nvm/versions/node/v20.11.0/bin/node")
    try file(".nvm/alias/default", "20\n"); try file("work/web/.nvmrc", "18\n")
    try file(".pyenv/versions/3.11.6/bin/python"); try file(".pyenv/versions/3.12.1/bin/python")
    try file(".pyenv/version", "3.12.1\n"); try file("work/ml/.python-version", "3.11\n")
    try file(".rbenv/versions/3.2.2/bin/ruby"); try file(".rbenv/versions/2.7.8/bin/ruby"); try file(".rbenv/version", "3.2.2\n")
    try file(".rustup/toolchains/stable-aarch64-apple-darwin/bin/rustc"); try file(".rustup/toolchains/1.75.0-aarch64-apple-darwin/bin/rustc")
    try file(".rustup/settings.toml", "default_toolchain = \"stable-aarch64-apple-darwin\"\n")
    try file("work/engine/rust-toolchain.toml", "[toolchain]\nchannel = \"1.75.0\"\n")
    try file(".android/avd/Pixel_8.avd/config.ini", "image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\n")
    try file("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/system.img")
    try file("Library/Android/sdk/system-images/android-30/default/x86_64/system.img")
    try file("Library/Android/sdk/build-tools/33.0.1/aapt"); try file("Library/Android/sdk/build-tools/34.0.0/aapt")
    try file(".cache/huggingface/hub/models--meta-llama--Llama-3.1-8B/blobs/abc")
    try file(".ollama/models/manifests/registry.ollama.ai/library/llama3/8b",
             #"{"config":{"digest":"sha256:c","size":500},"layers":[{"digest":"sha256:a","size":4000000000}]}"#)

    let context = DevContext(home: home, tree: try DiskScanner().scan(home), run: { _, _ in nil })
    func usage(_ ecosystem: DevEcosystem) -> [String: DevItem.Usage] {
        Dictionary(DevEnvironmentScanner.discover(ecosystem, context: context).items.map { ($0.title, $0.usage) },
                   uniquingKeysWith: { a, _ in a })
    }

    let node = usage(.node)
    #expect(node["Node v20.11.0"] == .active("当前默认") && node["Node v18.19.0"] == .used("1 个项目在用"))
    let python = usage(.python)
    #expect(python["Python 3.12.1"] == .active("当前默认") && python["Python 3.11.6"] == .used("1 个项目在用"))
    let ruby = usage(.ruby)
    #expect(ruby["Ruby 3.2.2"] == .active("当前默认") && ruby["Ruby 2.7.8"] == .unused("扫描范围内没有项目在用"))
    let rust = usage(.rust)
    #expect(rust["stable-aarch64-apple-darwin"] == .active("当前默认") && rust["1.75.0-aarch64-apple-darwin"] == .used("1 个项目在用"))
    let android = usage(.android)
    #expect(android["android-34/google_apis/arm64-v8a"] == .used("1 台模拟器在用"))
    #expect(android["android-30/default/x86_64"] == .unused("没有模拟器在用"))
    #expect(android["Build Tools 34.0.0"] == .used("最新版本") && android["Pixel_8"] != nil)
    let ai = DevEnvironmentScanner.discover(.ai, context: context).items
    #expect(Set(ai.map(\.title)) == ["meta-llama/Llama-3.1-8B", "llama3:8b"])
    #expect(ai.first { $0.title == "llama3:8b" }?.size == 4_000_000_500)
}
