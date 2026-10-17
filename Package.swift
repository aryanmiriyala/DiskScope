// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskScope",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskScopeCore", targets: ["DiskScopeCore"]),
        .library(name: "DiskScopeAI", targets: ["DiskScopeAI"]),
        .executable(name: "DiskScope", targets: ["DiskScopeApp"]),
    ],
    targets: [
        .target(
            name: "DiskScopeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Language model backends and Keychain access. Kept out of Core so that
        // DiskScopeCore stays pure, offline and dependency-free.
        .target(
            name: "DiskScopeAI",
            dependencies: ["DiskScopeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "DiskScopeApp",
            dependencies: ["DiskScopeCore", "DiskScopeAI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Tests run through a small in-package harness rather than XCTest or
        // swift-testing. Neither ships with the Command Line Tools, and this
        // project should be buildable and testable with nothing but a Swift
        // toolchain. Run them with `swift run DiskScopeTests`.
        .executableTarget(
            name: "DiskScopeTests",
            dependencies: ["DiskScopeCore", "DiskScopeAI"],
            path: "Tests/DiskScopeCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
