// swift-tools-version: 6.0
// Author: Timur Isaev

import PackageDescription

let package = Package(
  name: "AlloyStoreIdentity",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AlloyStoreIdentity",
      targets: ["AlloyStoreIdentity"]
    ),
    .executable(
      name: "AlloyStoreIdentityFaultProbe",
      targets: ["AlloyStoreIdentityFaultProbe"]
    )
  ],
  targets: [
    .target(name: "AlloyStoreIdentity"),
    .executableTarget(
      name: "AlloyStoreIdentityFaultProbe",
      dependencies: ["AlloyStoreIdentity"]
    ),
    .testTarget(
      name: "AlloyStoreIdentityTests",
      dependencies: ["AlloyStoreIdentity"]
    )
  ]
)
