# The hidden cost of `throw` (under XCTest)

**Throwing errors in a tight loop under XCTest is roughly 40× slower than the same code in a plain executable.** XCTest installs a global observer that turns *every* thrown error into an `NSError`, and `try?` does not save you. If you fuzz, run property‑based tests, or benchmark code that throws often, this is quietly costing you hours.

A full write‑up is in **[`the-hidden-cost-of-throw.pdf`](the-hidden-cost-of-throw.pdf)**. This repository is the minimal, runnable reproduction — clone it and check the numbers on your own machine.

## The numbers

Same loop, 20 million calls, half of them throw. Measured on a MacBook Pro M5, Swift 6.3.3, macOS 26, built in release:

| Context | Time | Relative |
|---|--:|--:|
| Executable (`swift run`) | **0.42 s** | ×1 |
| **XCTest (`swift test`)** | **16.80 s** | **×40** |
| XCTest, returning `nil` instead of throwing | **0.02 s** | ×0.05 |

The only variable is *throw vs `nil`*, and *XCTest vs not*. Returning `nil` under XCTest is ~850× faster than throwing under XCTest — proof that the cost is the `throw`, not the loop.

## Where this came from

This did not surface in a toy micro‑benchmark. It came out of a real workload, and that scale is precisely what exposes it.

It turned up whilst fuzzing the client of an encrypted messenger: **eight network‑facing "doors"** (parsers and decoders that take adversary‑chosen rubbish as the *normal* case), **600 million malformed inputs each — 4.8 billion in total — across ten parallel workers.** Three of those eight doors *throw* on rubbish, and rightly so (a hostile proxy response, a corrupt ratchet message, a tampered vault). So "throwing on rubbish" was not rare: it was the common case, hundreds of millions of times over.

The first attempt **stalled**: one core pinned at 100% for over an hour whilst the other nine sat idle. No crash, no warning. At the scale of an ordinary test — a handful of throws — nobody would ever see it. At fuzzing scale, it is catastrophic.

## The symptom

It throws no error and no crash. It shows up as slowness, and misleading slowness at that:

- **A single thread at 100%.** In a parallel test, nine cores finish and one is left alone, flat out, for minutes or hours. It looks like an ordinary straggler, but it isn't keeping pace.
- **The wall‑clock time balloons.** A run that ought to take minutes takes hours. No message, no clue.
- **No tool complains.** No crash, no leak, no warning. Memory sits flat.
- **It scales with the number of throws.** A small test never notices; one that throws millions of times does.

## Diagnosis: see it for yourself

Since there is no error, look at what the stuck thread is *doing*. Without stopping the process, sample its call stacks:

```sh
pgrep -f xctest                 # find the test process
sample <PID> 5 -f /tmp/out.txt  # sample 5 seconds of stacks
```

The running thread's stack gives the cause away, from the deepest frame downwards:

```
your loop
  parse(...)                                  // a function that THROWS
    swift_willThrowTypedImpl                   <- fires ON the throw
      XCTSwiftErrorObservation._installErrorObserver
        _swift_stdlib_bridgeErrorToNSError
          _getErrorUserInfoNSDictionary
            ...CFBasicHashFindBucket, isEqualToString...
```

Every time your code throws, XCTest intercepts it and builds a full `NSError`, complete with its `userInfo` dictionary. That is the whole cost, and none of it is yours.

## Why it happens

XCTest wants to warn you when a test throws an error you did not expect. To do that it installs a **global observer in the Swift runtime, hooked onto `willThrow`** — the point through which every exception passes at the moment it is thrown.

On each throw, that observer bridges the Swift error to an Objective‑C `NSError`: it allocates memory, builds the `userInfo` dictionary, compares strings. For a test that throws once or twice it is imperceptible. For a loop that throws millions of times it is ruinous — about **1.6 microseconds of pure overhead per throw**.

> **The detail that catches you out:** `try?` and `do/catch` will **not** save you. The observer fires *on* the throw, before your `catch` receives the error. It makes no difference that you catch it at once — the cost was already paid at the `throw`.

```swift
// This does NOT avoid the cost: the throw already happened.
for x in inputs {
    _ = try? parse(x)      // <- still paying the observer
}
```

In a plain executable — or in your shipping app — that observer does not exist. That is why the same code flies outside XCTest.

## Reproduce it yourself

```sh
git clone https://github.com/MagicYassin/xctest-throw-cost
cd xctest-throw-cost

swift run -c release Bench   # the loop in an executable
swift test -c release        # the same loop under XCTest (throwing vs nil)
```

The throwing function and the loop:

```swift
public enum ParseError: Error { case malformed }

@inline(never)
public func parse(_ x: Int) throws -> Int {
    if x & 1 == 0 { throw ParseError.malformed }   // throws for half the inputs
    return x
}

// identical loop in the test and the executable:
for i in 0..<20_000_000 { _ = try? parse(i) }
```

## How to fix it

1. **Move the hot loop out of XCTest.** Put it in an executable or benchmark target. With no observer, a throw costs next to nothing again. Best option for fuzzing and stress tests.
2. **Return an optional, don't throw.** On paths travelled millions of times, `return nil` instead of `throw` avoids the observer entirely (16.80 s → 0.02 s here).
3. **If it must stay in XCTest, don't throw in the loop.** Restructure so the exception is genuinely exceptional, not the common case.

> **The short rule:** XCTest's error observer makes every `throw` cost ~1.6 µs. Fine for hundreds of throws; ruinous for millions. If you are going to throw a great deal, do it outside XCTest.

---

*Measured on a MacBook Pro M5 · Swift 6.3.3 · macOS 26 · built in release. Surfaced whilst fuzzing the [Kalego](https://github.com/MagicYassin) client. Do check the numbers on your own machine — and open an issue if they differ.*
