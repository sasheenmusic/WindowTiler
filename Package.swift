// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WindowTiler",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WindowTilerCore", targets: ["WindowTilerCore"]),
        .executable(name: "WindowTiler", targets: ["WindowTilerApp"]),
    ],
    targets: [
        .target(name: "WindowTilerCore"),
        .executableTarget(
            name: "WindowTilerApp",
            dependencies: ["WindowTilerCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "WindowTilerCoreTests", dependencies: ["WindowTilerCore"]),
    ]
)
