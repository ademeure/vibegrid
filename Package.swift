// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeGrid",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibeGrid", targets: ["VibeGrid"])
    ],
    targets: [
        .executableTarget(
            name: "VibeGrid",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VibeGridTests",
            dependencies: ["VibeGrid"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
