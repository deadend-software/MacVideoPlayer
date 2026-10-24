// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let package = Package(
    name: "AudioEffectsChecks",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CEffects", cSettings: [.unsafeFlags([
            "-fobjc-arc", "-I\(root)/Vendor/FFmpeg/include", "-I\(root)/vplay/Audio",
            "-I\(root)/vplay/Effects", "-I\(root)/vplay/Utilities"
        ])], linkerSettings: [
            .linkedFramework("Foundation"), .linkedFramework("CoreImage"),
            .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
            .linkedFramework("Accelerate"),
            .unsafeFlags(["-L\(root)/Vendor/FFmpeg/lib", "-lavfilter.12", "-lavutil.61", "-lswresample.7", "-lavformat.63", "-lavcodec.63", "-lswscale.10",
                          "-Xlinker", "-rpath", "-Xlinker", "\(root)/Vendor/FFmpeg/lib"])
        ]),
        .testTarget(name: "AudioEffectsTests", dependencies: ["CEffects"])
    ]
)
