// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "spotvibe",
    platforms: [.macOS("26.0")],
    targets: [
        // Search, ranking and persistence. A library rather than part of the executable,
        // because an executable module's globals are not initialised when a test bundle
        // loads it — they read as null memory and crash on first access.
        .target(name: "SpotVibeCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The AppKit and SwiftUI shell.
        .executableTarget(
            name: "spotvibe",
            dependencies: ["SpotVibeCore"],
            // ponytail: single-threaded UI app, v6 strict concurrency buys nothing here.
            // Flip to .v6 if background indexing is ever added.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpotVibeCoreTests",
            dependencies: ["SpotVibeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
