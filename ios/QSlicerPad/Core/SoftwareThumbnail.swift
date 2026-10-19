//
//  SoftwareThumbnail.swift
//  Vignette du G-code (aperçu affiché par l'écran de l'imprimante) rendue par un petit
//  rasteriseur logiciel : tampon de profondeur, éclairage de Lambert, suréchantillonnage 2×2.
//
//  Pourquoi pas SceneKit : le moteur appelle le fournisseur de vignettes *pendant* le slicing,
//  depuis son thread ; un rendu SceneKit/Metal hors écran demandait le thread principal et un
//  appareil Metal, ce qui pouvait faire tomber l'app au moment de slicer. Ici : aucun appel
//  système, aucune dépendance au thread, résultat identique partout (donc testable sous Linux).
//

import Foundation
#if canImport(simd)
import simd
#endif

enum SoftwareThumbnail {
    struct Item {
        /// 9 floats par triangle, en coordonnées locales de l'objet.
        let triangles: [Float]
        /// Une matrice 4×4 colonne-majeure (repère monde) par instance.
        let matrices: [[Double]]
    }

    static let background: (UInt8, UInt8, UInt8) = (33, 33, 33)
    static let objectColor: (Double, Double, Double) = (250, 176, 64)

    /// Rend `width`×`height` pixels RGBA (lignes de haut en bas, alpha 255).
    static func render(items: [Item], boundsMin: Vec3, boundsMax: Vec3, width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let scale = 2                       // suréchantillonnage : bords lissés
        let w = width * scale, h = height * scale

        var camera = OrbitCamera.preset(.isometric, target: .zero, distance: 300)
        camera.frame(min: boundsMin, max: boundsMax, aspect: Double(width) / Double(max(height, 1)))
        let basis = camera.basis
        let eye = camera.position
        let tanHalf = tan(camera.fovDegrees * .pi / 360)
        let aspect = Double(w) / Double(h)
        let light = simd_normalize(Vec3(0.45, -0.55, 0.70))

        var depth = [Float](repeating: .infinity, count: w * h)
        var color = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            color[i * 3] = background.0; color[i * 3 + 1] = background.1; color[i * 3 + 2] = background.2
        }

        struct Projected { var x: Double, y: Double, invZ: Double }
        func project(_ p: Vec3) -> Projected? {
            let d = p - eye
            let z = simd_dot(d, basis.forward)
            guard z > 1 else { return nil }
            let x = simd_dot(d, basis.right) / (z * tanHalf * aspect)
            let y = simd_dot(d, basis.up) / (z * tanHalf)
            return Projected(x: (x * 0.5 + 0.5) * Double(w), y: (0.5 - y * 0.5) * Double(h), invZ: 1 / z)
        }

        for item in items {
            let count = item.triangles.count / 9
            for m in item.matrices where m.count == 16 {
                func world(_ k: Int, _ vertex: Int) -> Vec3 {
                    let o = k * 9 + vertex * 3
                    let x = Double(item.triangles[o]), y = Double(item.triangles[o + 1]), z = Double(item.triangles[o + 2])
                    return Vec3(m[0] * x + m[4] * y + m[8] * z + m[12],
                                m[1] * x + m[5] * y + m[9] * z + m[13],
                                m[2] * x + m[6] * y + m[10] * z + m[14])
                }
                for k in 0..<count {
                    let a = world(k, 0), b = world(k, 1), c = world(k, 2)
                    guard let pa = project(a), let pb = project(b), let pc = project(c) else { continue }
                    let area = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
                    guard abs(area) > 1e-9 else { continue }

                    var normal = simd_cross(b - a, c - a)
                    let length = simd_length(normal)
                    guard length > 1e-12 else { continue }
                    normal /= length
                    let shade = 0.35 + 0.65 * abs(simd_dot(normal, light))
                    let r = UInt8(min(objectColor.0 * shade, 255)), g = UInt8(min(objectColor.1 * shade, 255)),
                        bl = UInt8(min(objectColor.2 * shade, 255))

                    let minX = max(Int(min(pa.x, pb.x, pc.x).rounded(.down)), 0)
                    let maxX = min(Int(max(pa.x, pb.x, pc.x).rounded(.up)), w - 1)
                    let minY = max(Int(min(pa.y, pb.y, pc.y).rounded(.down)), 0)
                    let maxY = min(Int(max(pa.y, pb.y, pc.y).rounded(.up)), h - 1)
                    guard minX <= maxX, minY <= maxY else { continue }

                    for py in minY...maxY {
                        for px in minX...maxX {
                            let sx = Double(px) + 0.5, sy = Double(py) + 0.5
                            let w0 = ((pb.x - sx) * (pc.y - sy) - (pb.y - sy) * (pc.x - sx)) / area
                            let w1 = ((pc.x - sx) * (pa.y - sy) - (pc.y - sy) * (pa.x - sx)) / area
                            let w2 = 1 - w0 - w1
                            guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                            let invZ = Float(w0 * pa.invZ + w1 * pb.invZ + w2 * pc.invZ)
                            let index = py * w + px
                            let z = 1 / invZ
                            if z < depth[index] {
                                depth[index] = z
                                color[index * 3] = r; color[index * 3 + 1] = g; color[index * 3 + 2] = bl
                            }
                        }
                    }
                }
            }
        }

        // réduction 2×2 -> RGBA
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var sum = (0, 0, 0)
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let i = ((y * scale + dy) * w + x * scale + dx) * 3
                        sum.0 += Int(color[i]); sum.1 += Int(color[i + 1]); sum.2 += Int(color[i + 2])
                    }
                }
                let o = (y * width + x) * 4
                out[o] = UInt8(sum.0 / (scale * scale)); out[o + 1] = UInt8(sum.1 / (scale * scale))
                out[o + 2] = UInt8(sum.2 / (scale * scale)); out[o + 3] = 255
            }
        }
        return out
    }
}
