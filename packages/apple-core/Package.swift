// swift-tools-version: 6.2

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
        ),
        .library(
            name: "MacSupport",
            targets: ["MacSupport"]
        ),
        .executable(name: "SofaRemoteNativeHost", targets: ["SofaRemoteNativeHost"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0")
    ],
    targets: [
        .target(name: "AppleCore"),
        .target(
            name: "MacSupport",
            dependencies: [
                "AppleCore", .product(name: "X509", package: "swift-certificates")
            ]),
        .executableTarget(
            name: "SofaRemoteNativeHost",
            dependencies: ["MacSupport"],
            path: "Sources/SofaRemoteNativeHost"
        ),
        .testTarget(
            name: "AppleCoreTests",
            dependencies: ["AppleCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MacSupportTests", dependencies: ["MacSupport"])
    ]
)
