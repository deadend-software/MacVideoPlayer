// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioSyncChecks",
    targets: [
        .target(name: "CSync"),
        .testTarget(name: "AudioSyncTests", dependencies: ["CSync"])
    ]
)
