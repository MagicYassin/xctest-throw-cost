public enum ParseError: Error { case malformed }
// Una función que LANZA ante ~la mitad de las entradas — como un parser de red
// alimentado con basura. Trabajo trivial: el coste que midamos es el del throw.
@inline(never)
public func parse(_ x: Int) throws -> Int {
  if x & 1 == 0 { throw ParseError.malformed }
  return x
}

@inline(never)
public func parseOpt(_ x: Int) -> Int? {
  if x & 1 == 0 { return nil }   // devuelve nil en vez de lanzar
  return x
}
