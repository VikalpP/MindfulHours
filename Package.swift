// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActivityTracker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ActivityTracker", targets: ["ActivityTracker"]),
    ],
    targets: [
        .target(
            name: "ActivityTrackerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ActivityTracker",
            dependencies: ["ActivityTrackerCore"]
        ),
        .testTarget(
            name: "ActivityTrackerCoreTests",
            dependencies: ["ActivityTrackerCore"]
        ),
    ]
)
