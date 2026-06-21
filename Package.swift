// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UsageKun",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UsageKunCore", targets: ["UsageKunCore"]),
        .executable(name: "UsageKun", targets: ["UsageKun"]),
        .executable(name: "UsageKunCoreCheck", targets: ["UsageKunCoreCheck"])
    ],
    targets: [
        .target(
            name: "UsageKunCore",
            path: "Sources/UsageKunCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "UsageKun",
            dependencies: ["UsageKunCore"],
            path: "Sources/UsageKun"
        ),
        .executableTarget(
            name: "UsageKunCoreCheck",
            dependencies: ["UsageKunCore"],
            path: "Tests/UsageKunCoreCheck"
        )
    ]
)
