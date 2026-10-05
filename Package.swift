// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WindowTiler",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WindowTilerCore", targets: ["WindowTilerCore"]),
        .executable(name: "WindowTiler", targets: ["WindowTilerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "WindowTilerCore"),
        .executableTarget(
            name: "WindowTilerApp",
            dependencies: ["WindowTilerCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "WindowTilerCoreTests", dependencies: ["WindowTilerCore"]),
    ]
)
