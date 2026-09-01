import Testing
import Foundation
@testable import ThrowLib

// The same throwing loop under Swift Testing, for the three-way comparison.
//
//   swift test -c release --filter swiftTestingThrowCost
//
// Swift Testing installs its own willThrow handler (to capture backtraces for
// failure reports). It is cheaper than XCTest's NSError bridging and does NOT
// leak memory for swallowed throws — but it is still far above the executable
// baseline. "Just use Swift Testing" improves things; it is not a cure.

@Test func swiftTestingThrowCost() {
  let n = ProcessInfo.processInfo.environment["N"].flatMap { Int($0) } ?? 5_000_000
  print("ST willThrow handler under Swift Testing: \(willThrowHandlerState())")

  let throwSecs = timed(n, loopBare)
  let nilSecs   = timed(n, loopOptional)
  print(String(format: "ST bare throw   %8.3f s   %7.1f ns/it", throwSecs, throwSecs / Double(n) * 1e9))
  print(String(format: "ST return nil   %8.3f s   %7.1f ns/it", nilSecs,   nilSecs   / Double(n) * 1e9))

  // Memory stays flat here, unlike XCTest.
  let before = footprintMB(); _ = loopBare(4_000_000); let after = footprintMB()
  print(String(format: "ST memory over 2,000,000 throws · delta=%.0f MB", after - before))
}
