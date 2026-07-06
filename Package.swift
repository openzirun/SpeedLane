// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeedLane",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpeedLane",
            path: "Sources/SpeedLane"
        )
    ]
)
