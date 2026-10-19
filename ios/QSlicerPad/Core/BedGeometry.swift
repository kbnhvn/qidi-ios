//
//  BedGeometry.swift
//  Mathématiques du plateau, sans SceneKit : caméra orbitale (Z vers le haut),
//  rayons de sélection, intersections, aimantation. Pur Foundation + simd, donc
//  testé sous Linux ; la vue SceneKit n'est qu'une colle autour.
//

import Foundation
#if canImport(simd)
import simd
#endif

typealias Vec3 = SIMD3<Double>

struct Ray: Equatable {
    var origin: Vec3
    var direction: Vec3   // normalisée
}

enum Picking {
    /// Intersection avec le plan Z = `height`. nil si le rayon est parallèle ou part du mauvais côté.
    static func intersect(_ ray: Ray, planeZ height: Double) -> Vec3? {
        guard abs(ray.direction.z) > 1e-9 else { return nil }
        let t = (height - ray.origin.z) / ray.direction.z
        guard t >= 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    /// Distance le long du rayon jusqu'à la boîte (méthode des dalles), nil si manquée.
    static func intersect(_ ray: Ray, boxMin: Vec3, boxMax: Vec3) -> Double? {
        var tMin = 0.0, tMax = Double.infinity
        for axis in 0..<3 {
            let o = ray.origin[axis], d = ray.direction[axis]
            if abs(d) < 1e-12 {
                if o < boxMin[axis] || o > boxMax[axis] { return nil }
                continue
            }
            var t1 = (boxMin[axis] - o) / d
            var t2 = (boxMax[axis] - o) / d
            if t1 > t2 { swap(&t1, &t2) }
            tMin = max(tMin, t1)
            tMax = min(tMax, t2)
            if tMin > tMax { return nil }
        }
        return tMin
    }

    /// Möller–Trumbore : distance le long du rayon jusqu'au triangle, nil si manqué.
    static func intersect(_ ray: Ray, triangle a: Vec3, _ b: Vec3, _ c: Vec3) -> Double? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(ray.direction, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1 / det
        let s = ray.origin - a
        let u = simd_dot(s, p) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(ray.direction, q) * inv
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) * inv
        return t >= 0 ? t : nil
    }

    /// Premier triangle touché d'un maillage local (9 floats par triangle) déplacé par
    /// `matrix` (colonne-majeur, 16 valeurs). Retourne (index, distance).
    static func pickTriangle(_ ray: Ray, localTriangles: [Float], matrix: [Double]) -> (index: Int, distance: Double)? {
        guard matrix.count == 16 else { return nil }
        let m = simd_double4x4(columns: (
            SIMD4(matrix[0], matrix[1], matrix[2], matrix[3]),
            SIMD4(matrix[4], matrix[5], matrix[6], matrix[7]),
            SIMD4(matrix[8], matrix[9], matrix[10], matrix[11]),
            SIMD4(matrix[12], matrix[13], matrix[14], matrix[15])))
        func world(_ i: Int) -> Vec3 {
            let p = m * SIMD4(Double(localTriangles[i]), Double(localTriangles[i + 1]), Double(localTriangles[i + 2]), 1)
            return Vec3(p.x, p.y, p.z)
        }
        var best: (Int, Double)?
        for t in 0..<(localTriangles.count / 9) {
            let base = t * 9
            if let d = intersect(ray, triangle: world(base), world(base + 3), world(base + 6)),
               best == nil || d < best!.1 {
                best = (t, d)
            }
        }
        return best.map { (index: $0.0, distance: $0.1) }
    }
}

enum Snapping {
    /// Arrondit à un multiple de `step` (step <= 0 : inchangé).
    static func snap(_ value: Double, step: Double) -> Double {
        step > 0 ? (value / step).rounded() * step : value
    }

    /// Aimante un angle (degrés) au multiple de `step` le plus proche si l'écart est
    /// inférieur à `tolerance` ; sinon le laisse libre.
    static func snapAngle(_ degrees: Double, step: Double = 15, tolerance: Double = 4) -> Double {
        let nearest = (degrees / step).rounded() * step
        return abs(degrees - nearest) <= tolerance ? nearest : degrees
    }
}

enum BedBounds {
    /// Vrai si la boîte [min,max] sort du plateau (rectangle englobant) ou de la hauteur max.
    static func isOutside(min: Vec3, max: Vec3, bed: SceneBed, tolerance: Double = 1e-3) -> Bool {
        min.x < bed.minX - tolerance || max.x > bed.maxX + tolerance ||
        min.y < bed.minY - tolerance || max.y > bed.maxY + tolerance ||
        max.z > bed.maxHeight + tolerance
    }

    /// Décalage XY qui ramène la boîte dans le plateau (zéro si elle y est déjà).
    static func clampingShift(min: Vec3, max: Vec3, bed: SceneBed) -> SIMD2<Double> {
        func axis(_ lo: Double, _ hi: Double, _ bedLo: Double, _ bedHi: Double) -> Double {
            if hi - lo > bedHi - bedLo { return (bedLo + bedHi) / 2 - (lo + hi) / 2 }
            if lo < bedLo { return bedLo - lo }
            if hi > bedHi { return bedHi - hi }
            return 0
        }
        return SIMD2(axis(min.x, max.x, bed.minX, bed.maxX), axis(min.y, max.y, bed.minY, bed.maxY))
    }
}

/// Caméra orbitale, Z vers le haut, angles en degrés.
struct OrbitCamera: Equatable {
    var target = Vec3(0, 0, 0)
    var distance = 400.0
    /// 0 = on regarde vers +Y depuis -Y ; positif = tourne autour de Z.
    var azimuth = 30.0
    /// 0 = horizontal, 90 = vue de dessus.
    var elevation = 35.0
    var fovDegrees = 45.0

    static let minElevation = 2.0
    static let maxElevation = 90.0

    var position: Vec3 {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        return target + Vec3(distance * cos(el) * sin(az), -distance * cos(el) * cos(az), distance * sin(el))
    }

    /// Base orthonormée : (droite, haut écran, avant).
    var basis: (right: Vec3, up: Vec3, forward: Vec3) {
        let forward = simd_normalize(target - position)
        // Droite déduite de l'azimut (et non de forward × Z) : reste défini, et tourne
        // avec l'azimut, quand on regarde exactement de dessus.
        let az = azimuth * .pi / 180
        let right = Vec3(cos(az), sin(az), 0)
        let up = simd_normalize(simd_cross(right, forward))
        return (right, up, forward)
    }

    mutating func orbit(deltaX: Double, deltaY: Double, degreesPerPoint: Double = 0.4) {
        azimuth -= deltaX * degreesPerPoint
        elevation = min(max(elevation + deltaY * degreesPerPoint, Self.minElevation), Self.maxElevation)
    }

    /// Déplace la cible dans le plan de l'écran (glisser à deux doigts).
    mutating func pan(deltaX: Double, deltaY: Double, viewHeight: Double) {
        guard viewHeight > 0 else { return }
        let worldPerPoint = 2 * distance * tan(fovDegrees * .pi / 360) / viewHeight
        let b = basis
        target += (-b.right * deltaX + b.up * deltaY) * worldPerPoint
    }

    mutating func zoom(scale: Double, minDistance: Double = 30, maxDistance: Double = 3000) {
        guard scale > 0 else { return }
        distance = min(max(distance / scale, minDistance), maxDistance)
    }

    /// Cadre une boîte : cible au centre, distance pour la contenir.
    mutating func frame(min lo: Vec3, max hi: Vec3, aspect: Double = 1) {
        target = (lo + hi) / 2
        let radius = simd_length(hi - lo) / 2
        let vertical = fovDegrees * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * max(aspect, 0.1))
        let fit = radius / sin(min(vertical, horizontal) / 2)
        distance = max(fit * 1.05, 60)
    }

    /// Rayon passant par le point écran (origine en haut à gauche, en points).
    func ray(at point: SIMD2<Double>, viewSize: SIMD2<Double>) -> Ray {
        let b = basis
        let ndcX = (point.x / viewSize.x) * 2 - 1
        let ndcY = 1 - (point.y / viewSize.y) * 2
        let halfH = tan(fovDegrees * .pi / 360)
        let halfW = halfH * (viewSize.x / viewSize.y)
        let direction = simd_normalize(b.forward + b.right * (ndcX * halfW) + b.up * (ndcY * halfH))
        return Ray(origin: position, direction: direction)
    }

    static func preset(_ kind: Preset, target: Vec3, distance: Double) -> OrbitCamera {
        var cam = OrbitCamera(target: target, distance: distance)
        switch kind {
        case .top:       cam.azimuth = 0;  cam.elevation = 90
        case .front:     cam.azimuth = 0;  cam.elevation = Self.minElevation
        case .isometric: cam.azimuth = 35; cam.elevation = 35
        }
        return cam
    }

    enum Preset { case top, front, isometric }
}
