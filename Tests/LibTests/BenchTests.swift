import XCTest
import Foundation
@testable import Lib
final class BenchTests: XCTestCase {
  func testThrows() {
    let n = 20_000_000; let t0 = Date(); var ok = 0
    for i in 0..<n { if (try? parse(i)) != nil { ok += 1 } }
    print(String(format: "XCTEST throw · %.2f s · %.0f k/s", Date().timeIntervalSince(t0), Double(n)/Date().timeIntervalSince(t0)/1000))
  }
  func testOptional() {
    let n = 20_000_000; let t0 = Date(); var ok = 0
    for i in 0..<n { if parseOpt(i) != nil { ok += 1 } }
    print(String(format: "XCTEST nil   · %.2f s · %.0f k/s", Date().timeIntervalSince(t0), Double(n)/Date().timeIntervalSince(t0)/1000))
  }
}
