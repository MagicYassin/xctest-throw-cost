import Foundation

// ============================================================================
//  ThrowLib — the code under test, plus tiny measurement helpers.
//
//  The whole point of this package: the SAME functions and the SAME loops are
//  called from a plain executable (Sources/Bench), from an XCTest target, and
//  from a Swift Testing target. Only the host changes. Any difference in speed
//  or memory is the test framework's error observer, not the code.
// ============================================================================

// MARK: - Errors of different shapes

/// A bare enum error — the cheapest possible thrown value.
public enum BareError: Error { case malformed }

/// An error carrying an associated value.
public enum PayloadError: Error { case malformed(String) }

/// An error with a rich `userInfo` dictionary. Under XCTest this bridges to a
/// heavier `NSError`, so it costs more per throw (see the README).
public struct RichError: CustomNSError {
  public init() {}
  public static var errorDomain: String { "throwlib.parse" }
  public var errorCode: Int { 42 }
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: "malformed input at offset",
     "field": "header", "byte": 0xFF, "extra": [1, 2, 3]]
  }
}

// MARK: - Parsers that throw on ~half of their inputs
//
// Trivial work, so the cost we measure is the throw path, not the parsing.

@inline(never) public func parseBare(_ x: Int)  throws -> Int { if x & 1 == 0 { throw BareError.malformed };        return x }
@inline(never) public func parsePayload(_ x: Int) throws -> Int { if x & 1 == 0 { throw PayloadError.malformed("bad") }; return x }
@inline(never) public func parseRich(_ x: Int)  throws -> Int { if x & 1 == 0 { throw RichError() };                return x }
@inline(never) public func parseTyped(_ x: Int) throws(BareError) -> Int { if x & 1 == 0 { throw BareError.malformed }; return x }

/// Returns `nil` instead of throwing — the observer never fires. This is the
/// baseline the throwing versions are compared against.
@inline(never) public func parseOptional(_ x: Int) -> Int? { if x & 1 == 0 { return nil }; return x }

// MARK: - The loops (identical wherever they run)

@inline(never) public func loopBare(_ n: Int)    -> Int { var ok = 0; for i in 0..<n { if (try? parseBare(i))    != nil { ok += 1 } }; return ok }
@inline(never) public func loopPayload(_ n: Int) -> Int { var ok = 0; for i in 0..<n { if (try? parsePayload(i)) != nil { ok += 1 } }; return ok }
@inline(never) public func loopRich(_ n: Int)    -> Int { var ok = 0; for i in 0..<n { if (try? parseRich(i))    != nil { ok += 1 } }; return ok }
@inline(never) public func loopTyped(_ n: Int)   -> Int { var ok = 0; for i in 0..<n { if (try? parseTyped(i))   != nil { ok += 1 } }; return ok }
@inline(never) public func loopOptional(_ n: Int)-> Int { var ok = 0; for i in 0..<n { if parseOptional(i)       != nil { ok += 1 } }; return ok }

/// Times a loop and returns wall-clock seconds.
public func timed(_ n: Int, _ body: (Int) -> Int) -> Double {
  let t0 = DispatchTime.now().uptimeNanoseconds
  _ = body(n)
  return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
}

/// Convenience printer: label, seconds, nanoseconds per iteration, throughput.
public func row(_ label: String, _ dt: Double, _ n: Int) {
  print(String(format: "%-24@ %8.3f s   %7.1f ns/it   %8.0f k/s",
               label as NSString, dt, dt / Double(n) * 1e9, Double(n) / dt / 1000))
}

// MARK: - Memory

/// Physical memory footprint of the current process, in megabytes.
public func footprintMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let kr = withUnsafeMutablePointer(to: &info) { p in
    p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Same throwing loop, but draining the autorelease pool every iteration.
/// This keeps memory flat under XCTest — see the README's memory section.
@inline(never) public func loopBarePooled(_ n: Int) -> Int {
  var ok = 0
  for i in 0..<n { autoreleasepool { if (try? parseBare(i)) != nil { ok += 1 } } }
  return ok
}

// MARK: - Stack depth

/// Throws from a call stack `depth` frames deep (no tail-call optimization).
/// The observer captures the whole return-address stack, so cost grows with depth.
@inline(never) public func throwDeep(_ depth: Int) throws -> Int {
  if depth <= 0 { throw BareError.malformed }
  let r = try throwDeep(depth - 1)
  return r &+ depth
}
@inline(never) public func loopDeep(_ n: Int, _ depth: Int) -> Int {
  var ok = 0
  for _ in 0..<n { if (try? throwDeep(depth)) != nil { ok += 1 } }
  return ok
}

// MARK: - Concurrency

/// `threads` background threads, each throwing `per` times. Returns seconds.
/// Off the test's own thread the observer bails cheaply, so this scales.
public func concurrentThrows(threads: Int, per: Int) -> Double {
  let t0 = DispatchTime.now().uptimeNanoseconds
  let group = DispatchGroup()
  for _ in 0..<threads {
    DispatchQueue.global().async(group: group) {
      var ok = 0; for i in 0..<per { if (try? parseBare(i)) != nil { ok += 1 } }; _ = ok
    }
  }
  group.wait()
  return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
}

// MARK: - The willThrow slot
//
// `_swift_willThrow` (the internal, double-underscored Mach-O symbol) is a
// GLOBAL FUNCTION-POINTER VARIABLE in libswiftCore. The compiler emits, at every
// `throw` site, roughly "if this pointer isn't null, call it." In a normal
// binary the pointer is null, so a throw pays nothing. Test frameworks install
// their observer by atomically swapping their handler into this slot.
//
// These helpers read and clear that pointer. This is deliberately fragile:
// it relies on an internal runtime symbol. Pin it to a toolchain and test it.

private func slot(_ name: String) -> UnsafeMutablePointer<UnsafeRawPointer?>? {
  guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, name) else { return nil }
  return sym.assumingMemoryBound(to: UnsafeRawPointer?.self)
}
private let untypedSlot = "_swift_willThrow"
private let typedSlot   = "_swift_willThrowTypedImpl"

/// The currently installed untyped-throw observer (nil in a plain executable).
public func currentWillThrowHandler() -> UnsafeRawPointer? { slot(untypedSlot)?.pointee ?? nil }

/// A readable description of the slot state: armed, disarmed, or unavailable.
public func willThrowHandlerState() -> String {
  guard let s = slot(untypedSlot) else { return "unavailable (dlsym failed)" }
  return s.pointee == nil ? "nil (disarmed / no observer)" : "armed \(s.pointee!)"
}

/// Runs `body` with the throw observer disabled, then restores it.
///
/// This recovers full executable speed inside a test — but it is a sharp tool.
/// If the restore is skipped (an early return, a thrown error, a crash inside
/// `body`), throw observation stays dead for the rest of the process, silently
/// degrading every later test. `defer` makes that as safe as it can be; keep the
/// window tiny and never let an error escape `body`.
@discardableResult
public func withThrowObserverDisabled<R>(_ body: () -> R) -> R {
  let u = slot(untypedSlot), t = slot(typedSlot)
  let oldU = u?.pointee, oldT = t?.pointee
  u?.pointee = nil; t?.pointee = nil
  defer { u?.pointee = oldU; t?.pointee = oldT }
  return body()
}

// MARK: - Counting internal throws

/// A malformed-JSON decode, for counting how many times it throws internally.
struct SmallPayload: Codable { let a: Int }
@inline(never) public func decodeBadJSON() { _ = try? JSONDecoder().decode(SmallPayload.self, from: Data("{".utf8)) }
@inline(never) public func statMissingFile() { _ = try? FileManager.default.attributesOfItem(atPath: "/no/such/path/x") }
@inline(never) public func oneHandWrittenThrow() { _ = try? parseBare(0) }

/// Installs a raw counting handler in the willThrow slot and returns the old one.
/// Only safe to use where no framework observer is installed (i.e. the Bench
/// executable). Restore the old value when done.
public func installRawWillThrowHandler(_ p: UnsafeRawPointer?) -> UnsafeRawPointer? {
  guard let s = slot(untypedSlot) else { return nil }
  let old = s.pointee; s.pointee = p; return old
}
