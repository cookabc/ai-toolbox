// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZCodeUsageMenu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ZCodeUsageMenu", targets: ["ZCodeUsageMenu"]),
    ],
    targets: [
        .executableTarget(
            name: "ZCodeUsageMenu",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ZCodeUsageMenuTests",
            dependencies: ["ZCodeUsageMenu"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
