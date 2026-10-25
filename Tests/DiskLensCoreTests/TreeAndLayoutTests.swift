import CoreGraphics
import Foundation
import Testing
@testable import DiskLensCore

/// A tree built by hand: root → a (dir) → a1 (600), a2 (100); root → b (300); root → c (dir, empty).
private func sampleTree() -> FileTree {
    FileTree(rootPath: "/r",
             names: ["/r", "a", "b", "c", "a1", "a2"],
             parents: [-1, 0, 0, 0, 1, 1],
             kinds: [.directory, .directory, .file, .directory, .file, .file],
             ownSizes: [0, 0, 300, 0, 600, 100],
             modTimes: [0, 0, 0, 0, 0, 0],
             stats: ScanStats())
}

@Test func removingANodeShrinksAncestorsAndResorts() {
    var tree = sampleTree()
    #expect(tree.children(of: 0).map(Int.init) == [1, 2, 3])

    let removedNow = tree.remove(4)
    #expect(removedNow)

    #expect(tree.totalSizes[1] == 100)
    #expect(tree.totalSize == 400)
    #expect(tree.fileCounts[0] == 2)
    #expect(tree.children(of: 1).map(Int.init) == [5])
    // a (100) now sorts after b (300).
    #expect(tree.children(of: 0).map(Int.init) == [2, 1, 3])
    #expect(tree.isRemoved(4))
    let removedAgain = tree.remove(4)
    #expect(!removedAgain)
}

@Test func removingAFolderRemovesItsContents() {
    var tree = sampleTree()
    tree.remove(1)
    #expect(tree.isRemoved(5))
    #expect(tree.totalSize == 300)
    let childAgain = tree.remove(5)
    let root = tree.remove(0)
    #expect(!childAgain && !root)
}

@Test func ancestorCheckIncludesTheNodeItself() {
    let tree = sampleTree()
    #expect(tree.isAncestor(1, of: 4))
    #expect(tree.isAncestor(0, of: 4))
    #expect(tree.isAncestor(4, of: 4))
    #expect(!tree.isAncestor(2, of: 4))
}

@Test func categoriesComeFromExtensionsAndBundles() {
    #expect(FileCategory.of(name: "Movie.MOV", kind: .file) == .video)
    #expect(FileCategory.of(name: "index.ts", kind: .file) == .code)
    #expect(FileCategory.of(name: "Xcode.app", kind: .directory) == .application)
    #expect(FileCategory.of(name: "photos", kind: .directory) == .folder)
    #expect(FileCategory.of(name: ".zshrc", kind: .file) == .other)
    #expect(FileCategory.of(name: "noext", kind: .file) == .other)
    #expect(FileCategory.of(name: "Docker.raw", kind: .file) == .diskImage)
}

@Test func squarifiedBlocksMatchTheirAreasAndStayInBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let areas = [6000.0, 3000, 1000]
    let rects = TreemapLayout.squarify(areas, in: bounds)

    #expect(rects.count == 3)
    for (rect, area) in zip(rects, areas) {
        #expect(abs(Double(rect.width * rect.height) - area) < 0.01)
        #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect))
    }
    for i in 0..<rects.count {
        for j in (i + 1)..<rects.count {
            let overlap = rects[i].intersection(rects[j])
            #expect(overlap.isNull || overlap.width * overlap.height < 0.001)
        }
    }
}

@Test func layoutNestsFoldersAndSkipsTinyAndEmptyOnes() {
    let tree = sampleTree()
    let items = TreemapLayout.layout(tree, root: 0, in: CGRect(x: 0, y: 0, width: 400, height: 300))

    let nodes = items.map { Int($0.node) }
    #expect(nodes == [1, 4, 5, 2])  // a, then its children, then b; c is empty
    let a = items[0]
    #expect(!a.isLeaf && a.hasHeader && a.depth == 1)
    #expect(items[1].depth == 2 && items[1].isLeaf)
    #expect(a.rect.contains(items[1].rect))
}
