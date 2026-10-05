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
        ),
        .executable(
            name: "alloy-runtime-materialize",
            targets: ["AlloyRuntimeMaterialize"]
        )
    ],
    targets: [
        .target(
            name: "AlloyContentStore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
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
            dependencies: ["AlloyContentStore"],
            resources: [.copy("LayerFixtures")]
        ),
        .executableTarget(
            name: "AlloyRuntimeMaterialize",
            dependencies: ["AlloyContentStore"]
        )
    ]
)
