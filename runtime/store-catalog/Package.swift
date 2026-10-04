// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloyStoreCatalog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyStoreCatalog", targets: ["AlloyStoreCatalog"]),
        .executable(name: "alloy-store-catalog", targets: ["AlloyStoreCatalogCLI"])
    ],
    dependencies: [.package(path: "../store-identity"), .package(path: "../content-store")],
    targets: [
        .target(name: "AlloyStoreCatalog", dependencies: [
            .product(name: "AlloyStoreIdentity", package: "store-identity"),
            .product(name: "AlloyContentStore", package: "content-store")
        ]),
        .executableTarget(name: "AlloyStoreCatalogCLI", dependencies: ["AlloyStoreCatalog"]),
        .testTarget(name: "AlloyStoreCatalogTests", dependencies: ["AlloyStoreCatalog"])
    ]
)
