// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskLensCore", targets: ["DiskLensCore"]),
        .executable(name: "disklens", targets: ["disklens"]),
    ],
    targets: [
        .target(name: "DiskLensCore"),
        .executableTarget(name: "disklens", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
