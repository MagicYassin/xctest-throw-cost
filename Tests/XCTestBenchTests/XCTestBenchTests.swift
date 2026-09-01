import XCTest
import Foundation
import ThrowLib

// The SAME loops as the executable, now under XCTest. Compare the printed
// ns/it here against `swift run -c release Bench`.
//
//   swift test -c release --filter XCTestBench
//
// These print measurements; they don't assert. That's deliberate — the point is
// to read the numbers, not to pass/fail. The exception is `testWorkaround...`,
// which shows the disarm trick recovering executable speed.

let N = ProcessInfo.processInfo.environment["N"].flatMap { Int($0) } ?? 5_000_000

final class XCTestBench: XCTestCase {

  func test0_observerIsInstalled() {
    print("XT willThrow handler under XCTest: \(willThrowHandlerState())   (expected: armed)")
  }

  func test1_threeWayComparison() {
    print("### XCTest · N=\(N) ###")
    row("bare throw",    timed(N, loopBare),     N)
    row("payload throw", timed(N, loopPayload),  N)
    row("rich NSError",  timed(N, loopRich),     N)   // heavier userInfo -> costs more
    row("typed throw",   timed(N, loopTyped),    N)   // no faster here; observer hooks typed throws too
    row("return nil",    timed(N, loopOptional), N)   // baseline, unaffected
  }

  func test2_offThreadIsNearlyFree() {
    // The observer only does its work inside the test's own block. On a
    // background thread it bails in the null-check.
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { row("bg thread bare", timed(N, loopBare), N); sem.signal() }
    sem.wait()
  }

  func test3_workaround_disarmObserver() {
    let armed    = timed(N, loopBare)
    let disarmed = withThrowObserverDisabled { timed(N, loopBare) }
    let rearmed  = timed(N, loopBare)
    row("armed (before)",  armed,    N)
    row("DISARMED",        disarmed, N)
    row("rearmed (after)", rearmed,  N)
    print(String(format: "XT >>> speedup while disarmed: %.1fx", armed / disarmed))
  }
}
