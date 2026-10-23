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
            // Compiled into the app bundle by scripts/bundle.sh.
            exclude: ["Localizable.xcstrings"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "LaunchGridCoreTests",
            dependencies: ["LaunchGridCore"]
        ),
        .testTarget(
            name: "LaunchGridTests",
            dependencies: ["LaunchGrid", "LaunchGridCore"]
        ),
    ]
)
