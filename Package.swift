// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeGrid",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibeGrid", targets: ["VibeGrid"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")
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
            dependencies: [
                "VibeGrid",
                .product(name: "Testing", package: "swift-testing")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
