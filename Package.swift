// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SMCKitCore"),
    ]
)
