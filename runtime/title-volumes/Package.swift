// swift-tools-version: 6.2
// Author: Timur Isaev

import PackageDescription

let package = Package(
    name: "AlloyTitleVolumes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyTitleVolumes", targets: ["AlloyTitleVolumes"]),
        .executable(name: "alloy-volumes", targets: ["AlloyVolumes"]),
        .executable(name: "alloy-volumes-fault-probe", targets: ["AlloyVolumesFaultProbe"])
    ],
    dependencies: [.package(path: "../content-store")],
    targets: [
        .target(name: "AlloyTitleVolumes"),
        .executableTarget(name: "AlloyVolumes", dependencies: ["AlloyTitleVolumes"]),
        .testTarget(name: "AlloyTitleVolumesTests", dependencies: ["AlloyTitleVolumes"]),
        .executableTarget(name: "AlloyVolumesFaultProbe", dependencies: [
            "AlloyTitleVolumes", .product(name: "AlloyContentStore", package: "content-store")
        ])
    ]
)
