import XCTest
import Foundation
@testable import ThrowLib

// The memory side of the bug — the one part that is a genuine defect.
//
// Each observed throw under XCTest bridges to an autoreleased NSError, and the
// pool only drains at the end of the test method. Inside one long-running test,
// nothing is freed until it returns.
//
//   swift test -c release --filter Memory
//
// Run each in its OWN process for clean numbers — footprint doesn't return to the
// OS between methods, so a later method reuses the earlier one's mapped pages:
//   swift test -c release --filter Memory/testMemory_noPool_leaks
//
// WARNING: testMemory_noPool_leaks allocates several GB. Close other apps.

final class Memory: XCTestCase {

  func testMemory_noPool_leaks() {
    measureLeak("no pool", 4_000_000) { _ = loopBare($0) }
  }

  func testMemory_withPool_isFlat() {
    measureLeak("autoreleasepool", 4_000_000) { _ = loopBarePooled($0) }
  }

  private func measureLeak(_ name: String, _ n: Int, _ body: (Int) -> Void) {
    let before = footprintMB()
    body(n)
    let after = footprintMB()
    print(String(format: "MEM %-18@ %d throws · %.0f -> %.0f MB · delta=%.0f MB (%.0f B/throw)",
                 name as NSString, n / 2, before, after, after - before,
                 (after - before) * 1_048_576 / Double(n / 2)))
  }
}
