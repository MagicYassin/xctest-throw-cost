// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "xctest-throw-cost",
  targets: [
    // The code under test: parsers that throw, plus tiny measurement helpers.
    .target(name: "ThrowLib"),
    // The SAME loops, hosted in a plain executable (no test observer) — the baseline.
    .executableTarget(name: "Bench", dependencies: ["ThrowLib"]),
    // The SAME loops under XCTest, plus the memory and workaround experiments.
    .testTarget(name: "XCTestBenchTests", dependencies: ["ThrowLib"]),
    // The SAME loop under Swift Testing, for the three-way comparison.
    .testTarget(name: "SwiftTestingBenchTests", dependencies: ["ThrowLib"]),
  ]
)
