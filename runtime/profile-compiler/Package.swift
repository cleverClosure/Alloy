// swift-tools-version: 6.2
// Author: Tim Isaev

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
    targets: [
        .target(
            name: "AlloyProfileCompiler"
        ),
        .testTarget(
            name: "AlloyProfileCompilerTests",
            dependencies: ["AlloyProfileCompiler"]
        )
    ]
)
