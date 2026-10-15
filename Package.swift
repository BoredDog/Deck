// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Deck",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.3.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView", from: "0.12.1"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Deck",
            dependencies: [
                "KeyboardShortcuts", "MenuBarExtraAccess", "Yams", "ZIPFoundation",
                "CodeEditTextView", .product(name: "Textual", package: "textual"),
            ],
            path: "Sources/Deck"
        ),
        // Root helper installed once for website blocking during focus.
        .executableTarget(name: "DeckHelper", path: "Sources/DeckHelper"),
        .testTarget(name: "DeckTests", dependencies: ["Deck"], path: "Tests/DeckTests"),
    ],
    swiftLanguageModes: [.v5]
)
