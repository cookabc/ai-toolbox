// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIUsage", targets: ["AIUsage"]),
    ],
    targets: [
        .executableTarget(
            name: "AIUsage",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AIUsageTests",
            dependencies: ["AIUsage"]
        ),
    ]
)
