// swift-tools-version:6.0
//
// Typeforme — macOS local voice dictation helper.
// Bundle ID defaults to com.example.typeforme.mac. Apple Silicon, macOS 14+.
//
// Build and test through the Xcode-backed scripts in scripts/.
// `scripts/build-app.sh` wraps the built executable into Typeforme.app with the
// Info.plist and entitlements from Resources/.
//
import PackageDescription

let package = Package(
    name: "Typeforme",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Typeforme", targets: ["Typeforme"]),
    ],
    dependencies: [
        // Global hotkey recorder / monitor.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", .upToNextMajor(from: "2.4.0")),
        // Local HTTP server for Bridge. Do not hand-roll HTTP parsing/keep-alive.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", .upToNextMajor(from: "2.0.0")),
        // Bidirectional live preview transport for Bridge.
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", .upToNextMajor(from: "2.2.0")),
        // Fuzzy scoring for automatically derived speech vocabulary hints.
        .package(url: "https://github.com/ordo-one/FuzzyMatch.git", .upToNextMajor(from: "1.4.0")),
    ],
    targets: [
        .executableTarget(
            name: "Typeforme",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Hummingbird",       package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "FuzzyMatch",        package: "FuzzyMatch"),
            ],
            path: "Sources/Typeforme",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TypeformeTests",
            dependencies: ["Typeforme"],
            path: "Tests/TypeformeTests"
        ),
    ]
)
