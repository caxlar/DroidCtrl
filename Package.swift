// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidCtrl",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DroidCtrl",
            path: "Sources/DroidDeck"
        )
    ],
    swiftLanguageModes: [.v5]
)
