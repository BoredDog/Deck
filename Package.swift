// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Deck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Deck", path: "Sources/Deck"),
        .testTarget(name: "DeckTests", dependencies: ["Deck"], path: "Tests/DeckTests"),
    ]
)
