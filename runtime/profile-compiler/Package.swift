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
        )
    ],
    dependencies: [
        .package(path: "../../spikes/WINE-001/policy-probe")
    ],
    targets: [
        .target(
            name: "AlloyProfileCompiler",
            dependencies: [.product(name: "AlloyPolicySnapshot", package: "policy-probe")]
        ),
        .testTarget(
            name: "AlloyProfileCompilerTests",
            dependencies: ["AlloyProfileCompiler"]
        )
    ]
)
