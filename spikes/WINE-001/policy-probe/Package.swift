// swift-tools-version: 6.2
// Author: Timur Isaev

import PackageDescription

let package = Package(
    name: "AlloyPolicyProbe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AlloyPolicySnapshot",
            targets: ["AlloyPolicySnapshot"]
        ),
        .executable(
            name: "alloy-policy-compile",
            targets: ["AlloyPolicyCompile"]
        )
    ],
    targets: [
        .target(
            name: "AlloyPolicySnapshot"
        ),
        .executableTarget(
            name: "AlloyPolicyCompile",
            dependencies: ["AlloyPolicySnapshot"]
        ),
        .testTarget(
            name: "AlloyPolicySnapshotTests",
            dependencies: ["AlloyPolicySnapshot"]
        )
    ]
)
