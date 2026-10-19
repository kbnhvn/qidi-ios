//
//  ObjectSettings.swift
//  Réglages par objet : liste courte des options les plus utiles (le reste est cherché
//  dans le catalogue complet), et valeurs de départ d'un modificateur. Pur Foundation.
//

import Foundation

enum ObjectSettings {
    /// Options proposées d'emblée pour un objet / modificateur (toutes sont acceptées par le moteur).
    static let quickKeys = [
        "layer_height", "perimeters", "top_solid_layers", "bottom_solid_layers",
        "fill_density", "fill_pattern", "support_material", "seam_position",
        "ironing", "fuzzy_skin", "brim_width", "perimeter_speed", "infill_speed",
    ]

    enum ModifierShape: String, CaseIterable, Identifiable {
        case box, cylinder, sphere
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .box: return "cube"
            case .cylinder: return "cylinder"
            case .sphere: return "circle"
            }
        }
    }

    enum ModifierKind: Int, CaseIterable, Identifiable {
        case modifier = 0, supportBlocker = 1, supportEnforcer = 2
        var id: Int { rawValue }
    }

    /// Taille et centre (repère monde) d'un nouveau modificateur : 40 % de l'objet, au centre.
    static func defaultModifier(for instance: SceneInstance) -> (center: [Double], size: [Double]) {
        let center = zip(instance.min, instance.max).map { ($0 + $1) / 2 }
        let size = instance.size.map { Swift.max(2, ($0 * 0.4 * 2).rounded() / 2) }
        return (center, size)
    }

    /// Centre monde d'un volume à partir de son décalage local et de la matrice de l'instance
    /// (4×4 colonne-majeur) : c'est ce que demande `qsid_object_set_modifier`.
    static func worldCenter(local: [Double], matrix: [Double]) -> [Double] {
        guard local.count == 3, matrix.count == 16 else { return local }
        var world = [Double](repeating: 0, count: 3)
        for row in 0..<3 {
            var sum = matrix[12 + row]
            for column in 0..<3 { sum += matrix[column * 4 + row] * local[column] }
            world[row] = sum
        }
        return world
    }

    /// Plage de hauteurs proposée pour une nouvelle plage de couches : libre, après les existantes.
    static func defaultLayerRange(for object: SceneObject) -> (min: Double, max: Double)? {
        let height = object.instances.first.map { $0.max[2] - $0.min[2] } ?? object.localSize[2]
        guard height > 0.4 else { return nil }
        let start = object.layerRanges.map(\.max).max() ?? 0
        let end = Swift.min(height, start + Swift.max(1, (height / 4).rounded()))
        return end - start > 0.2 ? (start, end) : nil
    }
}

/// Opérations sur une sélection multiple (boîte englobante commune, déplacement borné).
enum SelectionGroup {
    static func bounds(of objects: [SceneObject]) -> (min: Vec3, max: Vec3)? {
        let instances = objects.flatMap(\.instances)
        guard !instances.isEmpty else { return nil }
        var lo = Vec3(repeating: .greatestFiniteMagnitude), hi = Vec3(repeating: -.greatestFiniteMagnitude)
        for i in instances {
            lo = Vec3(Swift.min(lo.x, i.min[0]), Swift.min(lo.y, i.min[1]), Swift.min(lo.z, i.min[2]))
            hi = Vec3(Swift.max(hi.x, i.max[0]), Swift.max(hi.y, i.max[1]), Swift.max(hi.z, i.max[2]))
        }
        return (lo, hi)
    }

    /// Décalage (dx, dy) borné pour que tout le groupe reste dans le plateau.
    static func clampedShift(of objects: [SceneObject], dx: Double, dy: Double, bed: SceneBed) -> (x: Double, y: Double) {
        guard let b = bounds(of: objects) else { return (dx, dy) }
        let fix = BedBounds.clampingShift(min: Vec3(b.min.x + dx, b.min.y + dy, b.min.z),
                                          max: Vec3(b.max.x + dx, b.max.y + dy, b.max.z), bed: bed)
        return (dx + fix.x, dy + fix.y)
    }
}
