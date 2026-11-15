// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WebRemoteSupport",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WebRemoteSupport", targets: ["WebRemoteSupport"])],
    dependencies: [
        .package(path: "../apple-core"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.6")
    ],
    targets: [
        .target(
            name: "WebRemoteSupport",
            dependencies: [
                .product(name: "AppleCore", package: "apple-core"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]),
        .testTarget(
            name: "WebRemoteSupportTests",
            dependencies: [
                "WebRemoteSupport", .product(name: "NIOEmbedded", package: "swift-nio")
            ])
    ]
)
