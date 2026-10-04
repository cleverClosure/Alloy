// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloySessionService", platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyRuntimeAPI", targets: ["AlloyRuntimeAPI"]),
        .library(name: "AlloyRuntimeService", targets: ["AlloyRuntimeService"]),
        .executable(name: "alloy-runtime-service", targets: ["AlloyRuntimeDaemon"]),
        .executable(name: "alloy-runtime-client", targets: ["AlloyRuntimeCLI"])
    ],
    targets: [
        .target(name: "AlloyRuntimeAPI"),
        .target(name: "AlloyRuntimeService", dependencies: ["AlloyRuntimeAPI"]),
        .executableTarget(name: "AlloyRuntimeDaemon", dependencies: ["AlloyRuntimeService"]),
        .executableTarget(name: "AlloyRuntimeCLI", dependencies: ["AlloyRuntimeAPI"]),
        .testTarget(name: "AlloyRuntimeServiceTests", dependencies: ["AlloyRuntimeService"])
    ]
)
