// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DroidCopy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DroidCopyCore"),
        .executableTarget(name: "DroidCopy", dependencies: ["DroidCopyCore"]),
        .testTarget(name: "DroidCopyCoreTests", dependencies: ["DroidCopyCore"]),
    ]
)
