// swift-tools-version: 6.0
// Author: Timur Isaev

import PackageDescription

let package = Package(
  name: "AlloyDiagnostics",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AlloyDiagnostics", targets: ["AlloyDiagnostics"]),
    .executable(name: "AlloyDiagnosticsSubject", targets: ["AlloyDiagnosticsSubject"])
  ],
  targets: [
    .target(name: "AlloyDiagnostics"),
    .executableTarget(name: "AlloyDiagnosticsSubject"),
    .testTarget(
      name: "AlloyDiagnosticsTests",
      dependencies: ["AlloyDiagnostics"],
      resources: [.copy("Fixtures")]
    )
  ]
)
