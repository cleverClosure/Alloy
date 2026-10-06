// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloyTrust", platforms: [.macOS(.v14)],
    products: [.library(name: "AlloyTrust", targets: ["AlloyTrust"])],
    targets: [
        .target(name: "AlloyTrust"),
        .testTarget(name: "AlloyTrustTests", dependencies: ["AlloyTrust"])
    ]
)
