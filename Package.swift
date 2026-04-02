// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeGrid",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ITermActivityKit", targets: ["ITermActivityKit"]),
        .executable(name: "VibeGrid", targets: ["VibeGrid"]),
        .executable(name: "ITermActivityDebug", targets: ["ITermActivityDebug"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2")
    ],
    targets: [
        .target(
            name: "ITermActivityKit",
            resources: [
                .copy("Resources/python")
            ]
        ),
        .executableTarget(
            name: "VibeGrid",
            dependencies: [
                "ITermActivityKit"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ITermActivityDebug",
            dependencies: [
                "ITermActivityKit"
            ]
        ),
        .testTarget(
            name: "VibeGridTests",
            dependencies: [
                "VibeGrid",
                "ITermActivityKit",
                .product(name: "Testing", package: "swift-testing")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
