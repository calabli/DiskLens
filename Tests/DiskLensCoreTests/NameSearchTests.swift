import Foundation
import Testing
@testable import DiskLensCore

@Test func nameSearchMatchesAnywhereInTheNameIgnoringCase() throws {
    let root = NSTemporaryDirectory() + "disklens-search-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    let files = ["Reports/Q3 Report.PDF": 300_000, "Reports/notes.txt": 10_000, "old/report-2.txt": 50_000,
                 "旅行/东京旅行照片.jpg": 80_000, "Café menu.txt": 20_000, "other.bin": 90_000]
    for (path, bytes) in files {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: full))
    }
    var tree = try DiskScanner().scan(root)

    let report = try #require(NameSearch.find("REPORT", in: tree, homePath: root))
    #expect(report.total == 3)
    // Largest first: the Reports folder holds Q3 Report.PDF and notes.txt.
    #expect(report.matches.map(\.name) == ["Reports", "Q3 Report.PDF", "report-2.txt"])
    #expect(report.matches[1].location == "~/Reports" && !report.matches[1].isDirectory)

    #expect(NameSearch.find("旅行", in: tree)?.matches.map(\.name) == ["旅行", "东京旅行照片.jpg"])
    #expect(NameSearch.find("café", in: tree)?.total == 1)
    #expect(NameSearch.find("  ", in: tree)?.total == 0)
    #expect(NameSearch.find("report", in: tree, limit: 1)?.matches.count == 1)

    tree.remove(try #require(tree.node(atPath: root + "/old")))
    #expect(NameSearch.find("report", in: tree)?.total == 2)
}
