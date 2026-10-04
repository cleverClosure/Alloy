// swift-tools-version: 6.0
// Author: Timur Isaev

import PackageDescription

let package = Package(
  name: "AlloyDiagnostics",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AlloyDiagnostics", targets: ["AlloyDiagnostics"])
  ],
  targets: [
    .target(name: "AlloyDiagnostics"),
    .testTarget(
      name: "AlloyDiagnosticsTests",
      dependencies: ["AlloyDiagnostics"],
      resources: [.copy("Fixtures")]
    )
  ]
)
