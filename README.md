# The cost of `throw` under XCTest

Under Apple's test frameworks, **every Swift `throw` is intercepted by a global
runtime hook.** In ordinary tests you never notice it. But if your code throws at
volume — a fuzzer, a property-based test, a stress suite, or any test that
exercises error paths millions of times — that hook makes throwing roughly **40×
slower** and quietly **leaks about 2 KB per throw** until the run runs out of
memory.

**It costs nothing in a shipped app.** The hook is never installed outside a test
process, and it never affects correctness. This is a test-time-only sharp edge —
but a real one, and one that gives you no warning when you hit it.

This repo is the reproducible proof: the same loops in a plain executable, in an
XCTest target, and in a Swift Testing target. Clone it and check the numbers on
your own machine — that is the whole point.

> Prefer to read it as a designed document? The full write-up is also here as a
> PDF: **[the-willthrow-tax.pdf](the-willthrow-tax.pdf)**.

---

## TL;DR

**The problem.** XCTest installs an error observer on the Swift runtime's
`_swift_willThrow` hook. On every throw it captures the call stack and bridges the
error to an autoreleased `NSError`. That work is fixed per throw (~1.4 µs) and the
`NSError`s are not freed until the test method ends.

**The fix — pick the one that fits:**

| If you want…                                   | Do this                                              |
| ---------------------------------------------- | ---------------------------------------------------- |
| The real fix for fuzzing / stress             | Move the hot loop into an **executable** target      |
| To keep it in XCTest, fast **and** leak-free  | Run the loop on a **background thread**              |
| Just to stop the OOM, minimal change          | Wrap the loop body in **`autoreleasepool { }`**      |
| To stop the leak but keep throwing            | Use **typed throws** `throws(MyError)`               |
| The error is really a common case             | **Return `nil`** instead of throwing on the hot path |

**Reproduce in 30 seconds** (Apple Silicon, Xcode 26 / Swift 6):

```sh
swift run  -c release Bench                     # baseline: fast, no observer
swift test -c release --filter XCTestBench      # same loops, ~40x slower
```

---

## How it was found

It surfaced while fuzzing [Kalego](https://github.com/MagicYassin/kalego), an
encrypted messenger, against the parsers that read data off the network. Three of
those parsers *throw* on bad input, by design — so under a fuzzer, throwing was
not the rare case. It was the common case, hundreds of millions of times.

The run stalled: one core pinned at 100% for over an hour, no crash, no error, no
leak warning. Because there was nothing to read, the next step was to look at what
the stuck thread was doing — a stack sample of the live process:

```sh
pgrep -f xctest
sample <pid> 5 -f /tmp/sample.txt
```

The sampled stack named the culprit:

```
your loop
  parse(...)
    swift_willThrowTypedImpl            <- fires on every throw
      XCTSwiftErrorObservation...       <- XCTest is watching
        _swift_stdlib_bridgeErrorToNSError
          _getErrorUserInfoNSDictionary
```

The loop wasn't slow. Something was intercepting *every throw*.

---

## Root cause

The Swift runtime has an internal global variable, `_swift_willThrow` — a
**function pointer**. The compiler emits, at every `throw` site, the equivalent of
*"if this pointer isn't null, call it."* In a normal binary the pointer is null,
so a throw pays nothing for it. (Confirmed: in the `Bench` executable the slot
reads `nil`.)

Test frameworks install themselves there with an atomic swap. This is Swift
Testing's registration, disassembled:

```
_swt_setWillThrowHandler:
    ldr   x8, [GOT: __swift_willThrow]   ; address of the slot
    swpal x0, x0, [x8]                    ; atomic swap: install, return the old
    ret
```

A symbol scan pins down exactly who installs the observer:

| Binary                         | willThrow references | Meaning                                          |
| ------------------------------ | -------------------- | ------------------------------------------------ |
| `XCTest.framework`             | 0                    | The framework itself is clean                    |
| `libXCTestSwiftSupport.dylib`  | 2 + observer         | The hook lives here (`XCTSwiftErrorObservation`) |
| `Testing.framework`            | 4                    | Swift Testing installs its own, too              |

That last row was contributed by **[u/ThatGuy739](https://www.reddit.com/r/swift/)**,
who reproduced the slowdown independently, located the hook in the support dylib,
and pointed out that Swift Testing references `_swift_willThrow` as well — so it is
not immune. Every measurement here confirms it.

Inside the observer, the per-throw work is: capture the call-stack return
addresses, bridge the Swift error to an autoreleased `NSError`, and record the
result under a lock — but **only while inside the block that wraps the running
test**. That "only inside the test's block" detail explains most of what follows.

---

## The numbers

The same function that throws on half its inputs, and the same loop compiled into
three hosts. Only the host differs. Release build; time is per loop iteration
(half of which throw), so the per-*throw* cost is roughly double.

| Host                         | ns / iteration | vs executable |
| ---------------------------- | -------------: | ------------: |
| Executable (`Bench`)         |          ~20   |          1×   |
| Swift Testing (`swift test`) |         ~291   |         ~14×  |
| XCTest (`swift test`)        |         ~812   |         ~40×  |
| XCTest (`xcodebuild` / CI)   |        ~1200   |         ~60×  |

The overhead is fixed at **~1.4 µs per actual throw**, and it is **linear** — flat
from 1M to 8M throws, so the hour-long stall was linear-but-brutal, not a runaway.
Numbers are from a MacBook Pro M5; yours will differ in absolute terms, but the
ratios hold. Run it and see.

> **Note on CI.** Under `xcodebuild test` — Xcode's runner, and most CI — Swift
> Testing is loaded alongside XCTest and the two observers chain, adding ~50% on
> top. The `swift test` numbers above are the optimistic floor.

---

## The second problem: memory

Speed is an annoyance. The memory is the part that is genuinely wrong, and the one
finding here that reads as a defect rather than an expensive-by-design trade-off.

Each observed throw bridges to an **autoreleased** `NSError`, and XCTest only
drains the autorelease pool at the *end* of the test method. Inside one
long-running test, nothing is freed:

| 2,000,000 throws in one test method | Memory Δ  | Per throw |
| ----------------------------------- | --------: | --------: |
| Plain loop                          | +4,031 MB |  2,113 B  |
| Wrapped in `autoreleasepool`        |    +0 MB  |      0 B  |

Two million throws cost **4 GB**. At fuzzing scale — hundreds of millions of throws
in a single test — this is not slow, it is an out-of-memory crash. Draining the
pool per iteration keeps it perfectly flat, which both proves the mechanism and
hands you a fix. **Swift Testing does not have this leak** (measured flat), because
it doesn't bridge to `NSError`.

Reproduce (run in its own process — footprint doesn't return to the OS between
methods):

```sh
swift test -c release --filter Memory/testMemory_noPool_leaks     # allocates several GB
swift test -c release --filter Memory/testMemory_withPool_isFlat  # stays flat
```

---

## You pay for throws you never wrote

A single call into a common Foundation API can throw more than once internally.
Each internal throw is observed. Counted directly (`Bench` installs a counting
handler and calls each API once):

| One call to…                                | Internal throws |
| ------------------------------------------- | --------------: |
| a hand-written `throw` (control)            |        1        |
| `JSONDecoder.decode` on malformed input     |        2        |
| `FileManager.attributesOfItem` (missing)    |        3        |
| `Int("abc")`, `URL(string:)` — return `nil` |        0        |

So a test that decodes malformed JSON pays roughly double, and one that stats
missing files pays triple — for throws inside the standard library. This is why
the problem isn't only a fuzzer's problem: **any test that exercises error paths at
volume pays it.** Optional-returning APIs (`Int`, `URL`) cost nothing.

---

## Solutions, in detail

Ranked. The first two are the safe answers; the rest are situational.

| Approach                                   | Speed | Memory | Caveat                                                        |
| ------------------------------------------ | :---: | :----: | ------------------------------------------------------------ |
| **Move the hot loop to an executable**     |  ✅   |   ✅   | Best for fuzzing / stress. No observer at all.               |
| **Run the loop on a background thread**    |  ✅   |   ✅   | Throws there aren't attributed to the test — fine for a fuzzer. |
| Wrap each iteration in `autoreleasepool`   |  ❌   |   ✅   | Stops the OOM even if you stay in XCTest. One line.          |
| Use typed throws `throws(E)`               |  ❌   |   ✅   | Removes the leak; CPU cost stays.                            |
| Return `nil` instead of throwing           |  ✅   |   ✅   | Changes the API; right when the "error" is really common.    |
| Disarm the observer around the loop        |  ✅   |   ✅   | **Sharp — see below.**                                       |

The last one is the clever option and the dangerous one. The observer lives in a
writable slot, so you can clear it around a hot loop and put it back. It recovers
full speed (~40× here) — but if you forget to restore it (an early return, a
thrown error, a crash mid-loop) throw observation stays dead for the rest of the
process, silently degrading every later test. If you use it, gate it behind
`defer` and keep the window tiny:

```swift
import Foundation

/// Clears the willThrow observer for the duration of `body`, then restores it.
/// Relies on an internal runtime symbol — pin it to a toolchain and test it.
func withThrowObserverDisabled<R>(_ body: () -> R) -> R {
    let slot = dlsym(dlopen(nil, RTLD_NOW), "_swift_willThrow")?
        .assumingMemoryBound(to: UnsafeRawPointer?.self)
    let saved = slot?.pointee
    slot?.pointee = nil
    defer { slot?.pointee = saved }   // or every later test loses observation
    return body()
}
```

If you can't leave XCTest and only need the memory safe, the honest minimum is one
line: wrap the loop body in `autoreleasepool { }`. If you're fuzzing, don't fight
it — put the loop in an executable.

---

## Reproduce it yourself

Requirements: macOS on Apple Silicon, Xcode 26 / Swift 6 (the package manifest is
`swift-tools-version: 6.0`, and the typed-throw example needs Swift 6).

```sh
git clone https://github.com/MagicYassin/xctest-throw-cost
cd xctest-throw-cost

# 1. Baseline — the executable, no observer. Also prints the API throw-counts.
swift run -c release Bench

# 2. The same loops under XCTest — ~40x slower, and the disarm workaround.
swift test -c release --filter XCTestBench

# 3. The same loop under Swift Testing — ~14x, no memory leak.
swift test -c release --filter swiftTestingThrowCost

# 4. The memory blowup and its fix (run each in its own process).
swift test -c release --filter Memory/testMemory_noPool_leaks
swift test -c release --filter Memory/testMemory_withPool_isFlat
```

Change the iteration count with `N`:

```sh
N=20000000 swift run  -c release Bench
N=20000000 swift test -c release --filter XCTestBench/test1_threeWay
```

### What's in the package

| Path                                              | What it is                                        |
| ------------------------------------------------- | ------------------------------------------------- |
| `Sources/ThrowLib`                                | the parsers, the loops, and the measurement helpers |
| `Sources/Bench`                                   | the executable baseline + the internal-throw counter |
| `Tests/XCTestBenchTests`                          | the XCTest comparison, memory tests, and workaround |
| `Tests/SwiftTestingBenchTests`                    | the same loop under Swift Testing                 |

The tests **print** their measurements rather than asserting — the point is to
read the numbers, not to pass or fail.

---

## Scope and caveats

- **Shipped apps are unaffected.** The hook is never installed in a normal binary.
- **Correctness is unaffected.** Assertions and `XCTUnwrap` failures record through
  a separate path; disarming the observer does not hide them.
- **Absolute times are hardware-dependent.** Compare ratios, and measure on your
  own machine.
- The disarm workaround relies on an internal, undocumented runtime symbol
  (`_swift_willThrow`). It may change between toolchains. Treat it as a last resort.

---

## Credits

- **Yassin Daoud** — [@MagicYassin](https://github.com/MagicYassin) — found it while
  fuzzing Kalego, and ran the investigation.
- **u/ThatGuy739** (r/swift) — reproduced it independently, located the hook in
  `libXCTestSwiftSupport.dylib`, and flagged that Swift Testing hooks
  `_swift_willThrow` too. The thread's most valuable contribution.
- **u/Dry_Hotel1100** (r/swift) — pushed the hardest questions (is a test's elapsed
  time even a valid criterion? could this be MainActor hops?), which is exactly
  what forced the rule-out experiments.

Discussion: the original [r/swift thread](https://www.reddit.com/r/swift/comments/1w2f07n/the_hidden_cost_of_throw_in_xctest_40x_slower/).

## License

MIT — see [LICENSE](LICENSE).
