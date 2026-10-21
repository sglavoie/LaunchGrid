// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchGrid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LaunchGrid", targets: ["LaunchGrid"]),
        .library(name: "LaunchGridCore", targets: ["LaunchGridCore"]),
    ],
    targets: [
        .target(
            name: "LaunchGridCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LaunchGrid",
            dependencies: ["LaunchGridCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "LaunchGridCoreTests",
            dependencies: ["LaunchGridCore"]
        ),
    ]
)
