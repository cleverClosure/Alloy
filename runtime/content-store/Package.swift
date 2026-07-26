// swift-tools-version: 6.2
// Author: Timur Isaev

import PackageDescription

let package = Package(
    name: "AlloyContentStore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AlloyContentStore",
            targets: ["AlloyContentStore"]
        ),
        .executable(
            name: "alloy-content-store-fault-probe",
            targets: ["AlloyContentStoreFaultProbe"]
        ),
        .executable(
            name: "alloy-content-store-stress-harness",
            targets: ["AlloyContentStoreStressHarness"]
        )
    ],
    targets: [
        .target(
            name: "AlloyContentStore"
        ),
        .executableTarget(
            name: "AlloyContentStoreFaultProbe",
            dependencies: ["AlloyContentStore"]
        ),
        .executableTarget(
            name: "AlloyContentStoreStressHarness",
            dependencies: ["AlloyContentStore"]
        ),
        .testTarget(
            name: "AlloyContentStoreTests",
            dependencies: ["AlloyContentStore"]
        )
    ]
)
