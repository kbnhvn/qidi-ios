// Les types SIMD de la bibliothèque standard existent sous Linux, pas le module
// `simd` d'Apple. Ce fichier (propre au paquet de test) fournit le sous-ensemble
// utilisé par les sources partagées avec l'app, avec la même sémantique.
#if !canImport(simd)
import Foundation

@inline(__always) func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
@inline(__always) func simd_length(_ a: SIMD3<Double>) -> Double { simd_dot(a, a).squareRoot() }
@inline(__always) func simd_normalize(_ a: SIMD3<Double>) -> SIMD3<Double> { a / simd_length(a) }
@inline(__always) func simd_cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inline(__always) func simd_min<T: SIMD>(_ a: T, _ b: T) -> T where T.Scalar: Comparable { a.replacing(with: b, where: b .< a) }
@inline(__always) func simd_max<T: SIMD>(_ a: T, _ b: T) -> T where T.Scalar: Comparable { a.replacing(with: b, where: b .> a) }

struct simd_double4x4 {
    var columns: (SIMD4<Double>, SIMD4<Double>, SIMD4<Double>, SIMD4<Double>)
    init(columns: (SIMD4<Double>, SIMD4<Double>, SIMD4<Double>, SIMD4<Double>)) { self.columns = columns }
    static func * (m: simd_double4x4, v: SIMD4<Double>) -> SIMD4<Double> {
        m.columns.0 * v.x + m.columns.1 * v.y + m.columns.2 * v.z + m.columns.3 * v.w
    }
}
#endif
