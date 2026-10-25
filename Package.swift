// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskLens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskLensCore", targets: ["DiskLensCore"]),
        .executable(name: "disklens", targets: ["disklens"]),
        .executable(name: "DiskLensApp", targets: ["DiskLensApp"]),
        .executable(name: "DiskLensAgent", targets: ["DiskLensAgent"]),
    ],
    targets: [
        .target(name: "DiskLensCore", resources: [.process("Resources")]),
        .executableTarget(name: "disklens", dependencies: ["DiskLensCore"]),
        .executableTarget(name: "DiskLensApp", dependencies: ["DiskLensCore"]),
        .executableTarget(name: "DiskLensAgent", dependencies: ["DiskLensCore"]),
        .testTarget(name: "DiskLensCoreTests", dependencies: ["DiskLensCore"]),
    ]
)
