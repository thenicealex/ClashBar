// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClashBar",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ClashBar", targets: ["ClashBar"]),
        .executable(name: "ClashBarProxyHelper", targets: ["ClashBarProxyHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "ProxyHelperShared",
            path: "Sources/ProxyHelperShared"),
        .executableTarget(
            name: "ClashBar",
            dependencies: ["ProxyHelperShared", .product(name: "Yams", package: "Yams")],
            path: "Sources/ClashBar",
            resources: [
                .process("Resources"),
            ]),
        .executableTarget(
            name: "ClashBarProxyHelper",
            dependencies: ["ProxyHelperShared"],
            path: "Sources/ProxyHelper/Daemon"),
        .testTarget(
            name: "ClashBarTests",
            dependencies: ["ClashBar", .product(name: "Yams", package: "Yams")]),
    ])
