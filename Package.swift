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
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AIUsageTests",
            dependencies: ["AIUsage"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
