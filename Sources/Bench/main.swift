import Foundation
import Lib
let n = 20_000_000
let t0 = Date()
var ok = 0
for i in 0..<n { if (try? parse(i)) != nil { ok += 1 } }
let dt = Date().timeIntervalSince(t0)
print(String(format: "EJECUTABLE  · %d llamadas (mitad lanzan) · %.2f s · %.0f k/s · ok=%d",
             n, dt, Double(n)/dt/1000, ok))
