// swift-tools-version: 6.2
// Author: Timur Isaev

import PackageDescription

let package = Package(
    name: "AlloyRollbackPrototype",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AlloyRollbackPrototype",
            targets: ["AlloyRollbackPrototype"]
        ),
        .executable(
            name: "alloy-rollback-probe",
            targets: ["AlloyRollbackProbe"]
        )
    ],
    targets: [
        .target(
            name: "AlloyRollbackPrototype"
        ),
        .executableTarget(
            name: "AlloyRollbackProbe",
            dependencies: ["AlloyRollbackPrototype"]
        ),
        .testTarget(
            name: "AlloyRollbackPrototypeTests",
            dependencies: ["AlloyRollbackPrototype"]
        )
    ]
)
