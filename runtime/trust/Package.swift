// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloyTrust", platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyTrust", targets: ["AlloyTrust"]),
        .executable(name: "alloy-trust-dev", targets: ["AlloyTrustDev"])
    ],
    targets: [
        .target(name: "AlloyTrust"),
        .executableTarget(name: "AlloyTrustDev", dependencies: ["AlloyTrust"]),
        .testTarget(name: "AlloyTrustTests", dependencies: ["AlloyTrust"])
    ]
)
