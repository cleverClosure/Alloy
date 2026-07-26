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
    )
  ],
  targets: [
    .target(name: "AlloyStoreIdentity"),
    .testTarget(
      name: "AlloyStoreIdentityTests",
      dependencies: ["AlloyStoreIdentity"]
    )
  ]
)
