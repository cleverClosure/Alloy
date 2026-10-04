// swift-tools-version: 6.0
// Author: Timur Isaev

import PackageDescription

let package = Package(
  name: "AlloyDiagnostics",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AlloyDiagnostics", targets: ["AlloyDiagnostics"]),
    .executable(name: "AlloyDiagnosticsSubject", targets: ["AlloyDiagnosticsSubject"]),
    .executable(name: "DiagnosticsOracle", targets: ["DiagnosticsOracle"])
  ],
  targets: [
    .target(name: "AlloyDiagnostics"),
    .executableTarget(name: "AlloyDiagnosticsSubject"),
    .executableTarget(name: "DiagnosticsOracle", dependencies: ["AlloyDiagnostics"]),
    .testTarget(
      name: "AlloyDiagnosticsTests",
      dependencies: ["AlloyDiagnostics"],
      resources: [.copy("Fixtures")]
    )
  ]
)
