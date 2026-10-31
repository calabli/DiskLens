import Foundation
import Testing
@testable import DiskLensCore

@Test func sizesPrintedByDockerAndHomebrewAreRead() {
    #expect(DevEnvironmentScanner.parseSize("1.21GB") == 1_210_000_000)
    #expect(DevEnvironmentScanner.parseSize("567MB") == 567_000_000)
    #expect(DevEnvironmentScanner.parseSize("12.3kB") == 12_300)
    #expect(DevEnvironmentScanner.parseSize("0B") == 0)
    #expect(DevEnvironmentScanner.parseSize("1,024 MB") == 1_024_000_000)
    #expect(DevEnvironmentScanner.parseSize("lots") == nil)
}

@Test func simulatorsAndRuntimesAreReadFromSimctl() throws {
    let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-5":[
          {"udid":"A1","name":"iPhone 15","state":"Booted","isAvailable":true,"dataPath":"/x/A1/data","dataPathSize":2048,"lastBootedAt":"2026-10-20T08:00:00Z"},
          {"udid":"B2","name":"iPad Air","state":"Shutdown","isAvailable":false}]}}
        """
    let parsed = try #require(AppleTools.parseDevices(Data(devices.utf8)))
    #expect(parsed.map(\.name) == ["iPad Air", "iPhone 15"])
    let phone = try #require(parsed.last)
    #expect(phone.dataSize == 2048 && phone.lastBooted != nil && phone.runtime.hasSuffix("iOS-17-5"))
    #expect(AppleTools.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-17-5") == "iOS 17.5")
    #expect(AppleTools.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == "watchOS 11.0")

    let runtimes = """
        {"8F3B":{"build":"21F79","deletable":true,"identifier":"8F3B","lastUsedAt":"2026-10-01T10:00:00.123Z",
                 "runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-5","sizeBytes":7300000000,"version":"17.5"}}
        """
    let runtime = try #require(AppleTools.parseRuntimes(Data(runtimes.utf8))?.first)
    #expect(runtime.identifier == "8F3B" && runtime.size == 7_300_000_000 && runtime.deletable && runtime.lastUsed != nil)
}

@Test func onlyTheNewestDeviceSupportPerModelCountsAsInUse() {
    let dates = ["iPhone16,1 27.0 (24A437)": 1.0, "iPhone16,1 27.2 (24B119)": 3.0, "iPhone16,1 27.0.1 (24A446)": 2.0,
                 "iPhone14,2 18.1 (22B83)": 1.0]
    let newest = AppleTools.newestPerDevice(Array(dates.keys)) { dates[$0].map(Date.init(timeIntervalSince1970:)) }
    #expect(newest == ["iPhone16,1 27.2 (24B119)", "iPhone14,2 18.1 (22B83)"])

    // The system version decides, not which folder happens to be newer on disk.
    let reversed = ["iPhone16,1 17.6 (21G80)": 9.0, "iPhone16,1 18.0 (22A3354)": 1.0]
    #expect(AppleTools.newestPerDevice(Array(reversed.keys)) { reversed[$0].map(Date.init(timeIntervalSince1970:)) }
            == ["iPhone16,1 18.0 (22A3354)"])
}

@Test func dockerImagesAndUsageAreRead() throws {
    let images = """
        {"ID":"abc123","Repository":"postgres","Tag":"16","Size":"432MB","CreatedSince":"3 weeks ago"}
        {"ID":"def456","Repository":"<none>","Tag":"<none>","Size":"1.1GB","CreatedSince":"2 months ago"}
        """
    let parsed = DockerTools.parseImages(images)
    #expect(parsed.map(\.reference) == ["postgres:16", "def456"])
    #expect(parsed.last?.isDangling == true && parsed.first?.size == 432_000_000)

    let df = """
        {"Active":"1","Reclaimable":"1.2GB (40%)","Size":"3.1GB","TotalCount":"5","Type":"Images"}
        {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}
        """
    let rows = DockerTools.parseSystemDF(df)
    #expect(rows.first == DockerTools.UsageRow(type: "Images", count: 5, size: 3_100_000_000, reclaimable: 1_200_000_000))
    #expect(rows.last?.reclaimable == 0)
}

@Test func homebrewCleanupTotalIsRead() {
    let text = """
        Would remove: /Users/me/Library/Caches/Homebrew/portable-ruby.tar.gz (12.7MB)
        ==> This operation would free approximately 52.2MB of disk space.
        """
    #expect(HomebrewTools.parseCleanupTotal(text) == 52_200_000)
    #expect(HomebrewTools.parseCleanupTotal("") == 0)
}

@Test func javaHomesAndGradleVersionsAreRead() {
    let listing = """
        Matching Java Virtual Machines (2):
            21 (arm64) "Oracle Corporation" - "Java SE 21" /Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
            1.8.0_275 (arm64) "Azul Systems, Inc." - "Zulu 8.50.0.1017" /Library/Java/JavaVirtualMachines/zulu-8.jdk/Contents/Home
        /Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home
        """
    let homes = JavaTools.parseJavaHomes(listing)
    #expect(homes.map(\.version) == ["21", "1.8.0_275"])
    #expect(homes.last?.vendor == "Azul Systems, Inc." && homes.last?.home.hasSuffix("zulu-8.jdk/Contents/Home") == true)

    #expect(JavaTools.gradleVersion(fromFolder: "gradle-8.10.2-all") == "8.10.2")
    #expect(JavaTools.gradleVersion(fromFolder: "gradle-8.5-bin") == "8.5")
    #expect(JavaTools.gradleVersion(fromWrapperProperties: "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.5-bin.zip\n") == "8.5")
}

@Test func commandsAreShownAsTypedAndLogged() throws {
    #expect(ToolCommand("xcrun", ["simctl", "delete", "A1"]).display == "xcrun simctl delete A1")
    #expect(ToolCommand("docker", ["image", "rm", "my image"]).display == "docker image rm 'my image'")

    let file = URL(fileURLWithPath: NSTemporaryDirectory() + "disklens-log-" + UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let log = CleanupLog(file: file)
    try log.add(CleanupRecord(items: [], commands: [.init(command: "brew cleanup", subject: "旧版本", size: 52_000_000)]))
    #expect(log.records().first?.commands?.first?.command == "brew cleanup")
    #expect(log.records().first?.totalSize == 52_000_000)
}

@Test func commandsRunWithoutAShell() throws {
    let echoed = try ToolCommand("echo", ["a; rm -rf ~", "$HOME"]).run(timeout: 5)
    #expect(echoed.succeeded && echoed.output == "a; rm -rf ~ $HOME\n")  // passed as words, never interpreted
    #expect(throws: ToolCommand.Failure.self) { try ToolCommand("no-such-tool-xyz", []).run() }
    #expect(try ToolCommand("false", []).run(timeout: 5).succeeded == false)
}
