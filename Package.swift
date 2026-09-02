// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SMCKitCore"),
        .target(name: "FanControlKit", dependencies: ["SMCKitCore"]),
        .executableTarget(name: "smcwrite", dependencies: ["SMCKitCore"]),
        .executableTarget(name: "analyze", dependencies: ["FanControlKit", "SMCKitCore"]),
        .executableTarget(name: "selftest", dependencies: ["FanControlKit", "SMCKitCore"]),
        .executableTarget(name: "FanControlApp", dependencies: ["FanControlKit", "SMCKitCore"]),
    ]
)
