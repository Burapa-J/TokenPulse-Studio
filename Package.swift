// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenPulse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenPulseCore", targets: ["TokenPulseCore"]),
        .executable(name: "TokenPulseApp", targets: ["TokenPulseApp"]),
        .executable(name: "TokenPulseCLI", targets: ["TokenPulseCLI"])
    ],
    targets: [
        .target(
            name: "TokenPulseCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "TokenPulseApp",
            dependencies: ["TokenPulseCore"]
        ),
        .executableTarget(
            name: "TokenPulseCLI",
            dependencies: ["TokenPulseCore"]
        ),
        .testTarget(
            name: "TokenPulseCoreTests",
            dependencies: ["TokenPulseCore"]
        )
    ]
)
