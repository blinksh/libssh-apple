// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "libssh-apple",
  platforms: [.macOS("11")],
  dependencies: [
    .package(url: "https://github.com/yury/FMake", from : "0.0.16"),
//    .package(path: "../FMake")
  ],
  targets: [
    .target(
      name: "libssh-apple",
      dependencies: ["FMake"]),
  ]
)
