// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloySessionService", platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyRuntimeAPI", targets: ["AlloyRuntimeAPI"]),
        .library(name: "AlloyRuntimeService", targets: ["AlloyRuntimeService"]),
        .executable(name: "alloy-runtime-service", targets: ["AlloyRuntimeDaemon"]),
        .executable(name: "alloy-runtime-client", targets: ["AlloyRuntimeCLI"]),
        .executable(name: "alloy-session-fixture", targets: ["AlloySessionFixture"])
    ],
    dependencies: [.package(path: "../store-catalog"), .package(path: "../content-store"),
                   .package(path: "../profile-compiler")],
    targets: [
        .target(name: "AlloyRuntimeAPI", dependencies: [
            .product(name: "AlloyStoreCatalog", package: "store-catalog"),
            .product(name: "AlloyContentStore", package: "content-store"),
            .product(name: "AlloyProfileCompiler", package: "profile-compiler")
        ]),
        .target(name: "AlloyRuntimeService", dependencies: ["AlloyRuntimeAPI"]),
        .executableTarget(name: "AlloyRuntimeDaemon", dependencies: ["AlloyRuntimeService"]),
        .executableTarget(name: "AlloyRuntimeCLI", dependencies: ["AlloyRuntimeAPI"]),
        .executableTarget(name: "AlloySessionFixture", dependencies: ["AlloyRuntimeAPI"]),
        .testTarget(name: "AlloyRuntimeServiceTests", dependencies: ["AlloyRuntimeService"])
    ]
)
