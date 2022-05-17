// swift-tools-version:5.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "WebRTC",
  platforms: [
    .iOS(.v13)
  ],
  products: [
    .library(
      name: "WebRTC",
      targets: ["WebRTC"]
    ),
  ],  
  targets: [
    .binaryTarget(name: "WebRTC", path: "WebRTC.xcframework")
  ]
)
