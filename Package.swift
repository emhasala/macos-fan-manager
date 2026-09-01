// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-fan-manager",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCKit"),
        .executableTarget(name: "fanctl", dependencies: ["SMCKit"]),
        .executableTarget(name: "fan-helper", dependencies: ["SMCKit"],
                          path: "Sources/FanHelper"),
        .executableTarget(name: "FanManagerApp", dependencies: ["SMCKit"]),
    ]
)
