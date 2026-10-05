// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloyClient", platforms: [.macOS(.v14)],
    products: [.executable(name: "alloy-client", targets: ["AlloyApp"])],
    targets: [
        .target(name: "AlloyClientCore"),
        .target(name: "AlloyClientUI", dependencies: ["AlloyClientCore"]),
        .executableTarget(name: "AlloyApp", dependencies: ["AlloyClientUI", "AlloyClientCore"]),
        .testTarget(name: "AlloyClientTests", dependencies: ["AlloyClientCore"])
    ]
)
