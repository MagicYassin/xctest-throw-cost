import Foundation
import ThrowLib

// The baseline: the same loops, in a plain executable with no test observer.
//
//   swift run -c release Bench          (release — the honest numbers)
//   N=20000000 swift run -c release Bench

let N = ProcessInfo.processInfo.environment["N"].flatMap { Int($0) } ?? 5_000_000

print("### Executable (no observer) · N=\(N) ###")
print("willThrow handler in this process: \(willThrowHandlerState())   (expected: nil)")
row("bare throw",    timed(N, loopBare),     N)
row("payload throw", timed(N, loopPayload),  N)
row("rich NSError",  timed(N, loopRich),     N)
row("typed throw",   timed(N, loopTyped),    N)
row("return nil",    timed(N, loopOptional), N)

print("\n### Scaling (bare throw) — expect a flat ns/it (linear) ###")
for k in [1_000_000, 5_000_000, 10_000_000, 20_000_000] { row("N=\(k)", timed(k, loopBare), k) }

// Count how many times common APIs throw *internally*, per single call.
// You pay the observer once per internal throw — for throws you never wrote.
print("\n### Internal throws per API call (executable) ###")
nonisolated(unsafe) var throwCount = 0
let counter: @convention(c) (UnsafeRawPointer?) -> Void = { _ in throwCount += 1 }
let old = installRawWillThrowHandler(UnsafeRawPointer(unsafeBitCast(counter, to: UnsafeRawPointer.self)))
func count(_ name: String, _ body: () -> Void) {
  throwCount = 0; body()
  print(String(format: "  %-34@ %d internal throw(s)", name as NSString, throwCount))
}
count("hand-written throw (control = 1)", oneHandWrittenThrow)
count("JSONDecoder.decode (malformed)",   decodeBadJSON)
count("FileManager.attributesOfItem",     statMissingFile)
_ = installRawWillThrowHandler(old)   // restore (nil in the executable)
