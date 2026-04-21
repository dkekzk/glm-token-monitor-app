// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "glm-token-monitor-app",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "glm-token-monitor-app", targets: ["glm-token-monitor-app"]),
    ],
    targets: [
        .executableTarget(
            name: "glm-token-monitor-app"
        ),
    ]
)
