// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoundStage",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "SoundStage", path: "Sources/SoundStage")
    ]
)
