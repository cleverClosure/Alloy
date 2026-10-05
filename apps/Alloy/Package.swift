// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloyClient", platforms: [.macOS(.v14)],
    products: [.executable(name: "alloy-client", targets: ["AlloyApp"]),
               .executable(name: "alloy-client-probe", targets: ["AlloyClientProbe"])],
    dependencies: [.package(path: "../../runtime/session-service")],
    targets: [
        .target(name: "AlloyClientCore", dependencies: [
            .product(name: "AlloyRuntimeAPI", package: "session-service")
        ]),
        .target(name: "AlloyClientUI", dependencies: ["AlloyClientCore"]),
        .executableTarget(name: "AlloyApp", dependencies: ["AlloyClientUI", "AlloyClientCore"]),
        .executableTarget(name: "AlloyClientProbe", dependencies: ["AlloyClientCore"]),
        .testTarget(name: "AlloyClientTests", dependencies: ["AlloyClientCore"])
    ]
)
