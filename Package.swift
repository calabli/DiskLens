// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskLensCore", targets: ["DiskLensCore"]),
        .executable(name: "disklens", targets: ["disklens"]),
        .executable(name: "DiskLensApp", targets: ["DiskLensApp"]),
    ],
    targets: [
        .target(name: "DiskLensCore", resources: [.process("Resources")]),
        .executableTarget(name: "disklens", dependencies: ["DiskLensCore"]),
        .executableTarget(name: "DiskLensApp", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
