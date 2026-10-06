// swift-tools-version: 6.2
// Author: Timur Isaev

import PackageDescription

let package = Package(
    name: "AlloyTitleVolumes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyTitleVolumes", targets: ["AlloyTitleVolumes"]),
        .executable(name: "alloy-volumes", targets: ["AlloyVolumes"])
    ],
    targets: [
        .target(name: "AlloyTitleVolumes"),
        .executableTarget(name: "AlloyVolumes", dependencies: ["AlloyTitleVolumes"]),
        .testTarget(name: "AlloyTitleVolumesTests", dependencies: ["AlloyTitleVolumes"])
    ]
)
