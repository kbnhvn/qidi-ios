struct simd_float4x4 {}
final class BedSceneCoordinator { static func simdMatrix(_ m: [Double]) -> simd_float4x4 { simd_float4x4() } }
final class ThumbnailProvider {
    struct Item { let triangles: [Float]; let matrices: [simd_float4x4] }
    init(items: [Item], boundsMin: SIMD3<Double>, boundsMax: SIMD3<Double>) {}
    func render(width: Int, height: Int) -> [UInt8]? { nil }
}
import Foundation
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { true }
    func stopAccessingSecurityScopedResource() {}
}
