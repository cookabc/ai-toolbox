// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIToolbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AIToolbox", targets: ["AIToolbox"]),
    ],
    targets: [
        .executableTarget(
            name: "AIToolbox",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AIToolboxTests",
            dependencies: ["AIToolbox"]
        ),
    ]
)
