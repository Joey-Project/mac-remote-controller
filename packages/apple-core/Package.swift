// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppleCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AppleCore",
            targets: ["AppleCore"]
        )
    ],
    targets: [
        .target(name: "AppleCore")
    ]
)
