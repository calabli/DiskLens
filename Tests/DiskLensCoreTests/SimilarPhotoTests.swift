import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DiskLensCore

/// A picture of random colored shapes: the same seed draws the same picture.
private func picture(seed: UInt64, width: Int, height: Int) -> CGImage {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state % 1000) / 1000
    }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let (w, h) = (CGFloat(width), CGFloat(height))
    context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for _ in 0..<60 {
        context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        let rect = CGRect(x: next() * w, y: next() * h, width: next() * w / 2, height: next() * h / 2)
        next() > 0.5 ? context.fill(rect) : context.fillEllipse(in: rect)
    }
    return context.makeImage()!
}

private func write(_ image: CGImage, to path: String, quality: CGFloat = 0.9) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func makeHome() throws -> String {
    let base = NSTemporaryDirectory() + "disklens-photos-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return URL(fileURLWithPath: base).resolvingSymlinksInPath().path
}

private func find(in home: String, cache: PhotoPrintCache = PhotoPrintCache()) throws -> [SimilarPhotoGroup] {
    let finder = SimilarPhotoFinder(homePath: home, cache: cache)
    finder.minimumSize = 1
    return try finder.find(in: try DiskScanner().scan(home))
}

@Test func findsAResizedCopyAndKeepsTheLargerPhoto() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try write(picture(seed: 1, width: 1600, height: 1200), to: home + "/Pictures/original.jpg")
    try write(picture(seed: 1, width: 800, height: 600), to: home + "/Downloads/small.jpg", quality: 0.6)
    try write(picture(seed: 2, width: 1600, height: 1200), to: home + "/Pictures/other.jpg")

    let groups = try find(in: home)
    #expect(groups.count == 1)
    #expect(groups[0].photos.map(\.path) == [home + "/Pictures/original.jpg", home + "/Downloads/small.jpg"])
    #expect(groups[0].photos[0].width == 1600)
    #expect(groups[0].reclaimable > 0)
}

@Test func unrelatedPhotosAreNotGrouped() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    for seed in 1...6 {
        try write(picture(seed: UInt64(seed), width: 1200, height: 900), to: home + "/Pictures/\(seed).jpg")
    }
    #expect(try find(in: home).isEmpty)
}

@Test func leavesOutSmallImagesLibraryAndTrash() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try write(picture(seed: 1, width: 300, height: 300), to: home + "/Pictures/icon-a.jpg")
    try write(picture(seed: 1, width: 300, height: 300), to: home + "/Pictures/icon-b.jpg")
    try write(picture(seed: 2, width: 1200, height: 900), to: home + "/Pictures/photo.jpg")
    try write(picture(seed: 2, width: 1200, height: 900), to: home + "/Library/Caches/copy.jpg")
    try write(picture(seed: 2, width: 1200, height: 900), to: home + "/.Trash/copy.jpg")
    try write(picture(seed: 2, width: 1200, height: 900), to: home + "/Some.app/Contents/copy.jpg")
    #expect(try find(in: home).isEmpty)
}

@Test func aSecondSearchReusesThePhotosItHasRead() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let path = home + "/Pictures/a.jpg"
    try write(picture(seed: 1, width: 1200, height: 900), to: path)
    try write(picture(seed: 1, width: 1200, height: 900), to: home + "/Pictures/b.jpg", quality: 0.6)
    let cache = PhotoPrintCache()
    #expect(try find(in: home, cache: cache).count == 1)

    // Still a valid picture of the same length would be a real change; an unreadable
    // file with the old date and length can only match through the cache.
    let info = try FileManager.default.attributesOfItem(atPath: path)
    let length = info[.size] as! Int
    try Data(repeating: 0, count: length).write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.modificationDate: info[.modificationDate]!], ofItemAtPath: path)
    #expect(try find(in: home, cache: cache).count == 1)
}
