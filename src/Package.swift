// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OverPass",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "OverPass",
            path: "Sources/OverPass",
            resources: [.copy("Logos"), .copy("Schema")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
