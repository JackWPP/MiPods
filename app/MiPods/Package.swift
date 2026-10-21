// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiPods",
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "MiPods", targets: ["MiPodsMenuBar"]),
        .library(name: "MiPodsCore", targets: ["MiPodsCore"])
    ],
    targets: [
        .target(name: "MiPodsCore", path: "Sources/MiPodsCore"),
        .executableTarget(
            name: "MiPodsMenuBar",
            dependencies: ["MiPodsCore"],
            path: "Sources/MiPodsMenuBar"
        ),
        .testTarget(
            name: "MiPodsCoreTests",
            dependencies: ["MiPodsCore"],
            path: "Tests/MiPodsCoreTests"
        )
    ]
)
