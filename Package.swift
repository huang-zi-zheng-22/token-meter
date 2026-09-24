// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TokenUsageWidget",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "TokenUsageWidget", targets: ["TokenUsageWidget"]),
    ],
    targets: [
        .executableTarget(
            name: "TokenUsageWidget",
            path: "Sources/TokenUsageWidget"
        ),
    ]
)
