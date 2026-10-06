// swift-tools-version: 6.2
// Author: Timur Isaev

import PackageDescription

let package = Package(
    name: "AlloyProfileCompiler",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AlloyProfileCompiler",
            targets: ["AlloyProfileCompiler"]
        ),
        .executable(name: "alloy-snapshot-export", targets: ["AlloySnapshotExport"])
    ],
    dependencies: [
        .package(path: "../../spikes/WINE-001/policy-probe"),
        .package(path: "../trust")
    ],
    targets: [
        .target(
            name: "AlloyProfileCompiler",
            dependencies: [
                .product(name: "AlloyPolicySnapshot", package: "policy-probe"),
                .product(name: "AlloyTrust", package: "trust")
            ]
        ),
        .executableTarget(name: "AlloySnapshotExport", dependencies: ["AlloyProfileCompiler"]),
        .testTarget(
            name: "AlloyProfileCompilerTests",
            dependencies: ["AlloyProfileCompiler"]
        )
    ]
)
