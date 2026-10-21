// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidDeck",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DroidDeck",
            path: "Sources/DroidDeck"
        )
    ],
    swiftLanguageModes: [.v5]
)
