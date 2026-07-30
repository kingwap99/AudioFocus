// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioFocus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AudioFocus",
            path: "Sources/AudioFocus"
        )
    ]
)
