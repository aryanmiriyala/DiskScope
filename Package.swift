// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskScope",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskScopeCore", targets: ["DiskScopeCore"]),
    ],
    targets: [
        .target(
            name: "DiskScopeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
