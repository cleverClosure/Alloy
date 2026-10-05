// swift-tools-version: 6.2
// Author: Timur Isaev
import PackageDescription

let package = Package(
    name: "AlloyDiagnosticsIntegration", platforms: [.macOS(.v14)],
    products: [
        .library(name: "AlloyDiagnosticsIntegration", targets: ["AlloyDiagnosticsIntegration"]),
        .executable(name: "alloy-diagnostics", targets: ["AlloyDiagnosticClient"])
    ],
    dependencies: [.package(path: "../session-service"), .package(path: "../../spikes/DIAG-001/prototype")],
    targets: [
        .target(name: "AlloyDiagnosticsIntegration", dependencies: [
            .product(name: "AlloyRuntimeAPI", package: "session-service"),
            .product(name: "AlloyDiagnostics", package: "prototype")
        ]),
        .executableTarget(name: "AlloyDiagnosticClient", dependencies: ["AlloyDiagnosticsIntegration"]),
        .testTarget(name: "AlloyDiagnosticsIntegrationTests", dependencies: ["AlloyDiagnosticsIntegration"])
    ]
)
