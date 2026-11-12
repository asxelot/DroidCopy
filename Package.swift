// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DroidCopy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DroidCopyCore"),
        .executableTarget(name: "DroidCopy", dependencies: ["DroidCopyCore"]),
        // A fake adb and small async helpers shared by both test targets.
        .target(name: "DroidCopyTestSupport", dependencies: ["DroidCopyCore"], path: "Tests/DroidCopyTestSupport"),
        .testTarget(name: "DroidCopyCoreTests", dependencies: ["DroidCopyCore", "DroidCopyTestSupport"]),
        .testTarget(name: "DroidCopyAppTests", dependencies: ["DroidCopy", "DroidCopyCore", "DroidCopyTestSupport"]),
    ]
)
