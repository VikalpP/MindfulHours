// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MindfulHours",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MindfulHours", targets: ["MindfulHours"]),
    ],
    targets: [
        .target(
            name: "MindfulHoursCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MindfulHours",
            dependencies: ["MindfulHoursCore"]
        ),
        .testTarget(
            name: "MindfulHoursCoreTests",
            dependencies: ["MindfulHoursCore"]
        ),
    ]
)
