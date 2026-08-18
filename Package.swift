// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "KeychainStore",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "KeychainStore", targets: ["KeychainStore"])
  ],
  targets: [
    .target(
      name: "KeychainStore",
      path: "src",
      exclude: ["index.ts"],
      sources: ["native.swift"],
      swiftSettings: [.define("KEYCHAIN_STORE_SWIFT_PACKAGE")],
    ),
    .testTarget(name: "KeychainStoreTests", dependencies: ["KeychainStore"]),
  ],
)
