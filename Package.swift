// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "throwdemo",
  targets: [
    .target(name: "Lib"),
    .executableTarget(name: "Bench", dependencies: ["Lib"]),
    .testTarget(name: "LibTests", dependencies: ["Lib"]),
  ])
