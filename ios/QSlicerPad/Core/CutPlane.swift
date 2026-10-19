//
//  CutPlane.swift
//  Plan de coupe d'un objet : un plan aligné sur un axe du plateau (horizontal, ou vertical
//  selon X / Y). Pur Foundation, testé sous Linux ; le moteur fait la coupe (CutUtils).
//

import Foundation

struct CutPlane: Equatable {
    enum Axis: String, CaseIterable, Identifiable {
        case x, y, z
        var id: String { rawValue }
        var index: Int { self == .x ? 0 : (self == .y ? 1 : 2) }
        var normal: [Double] {
            switch self {
            case .x: return [1, 0, 0]
            case .y: return [0, 1, 0]
            case .z: return [0, 0, 1]
            }
        }
    }

    /// Côtés conservés : valeur de `keep` de l'ABI (bit 0 = dessus, bit 1 = dessous).
    enum Keep: Int, CaseIterable, Identifiable {
        case upper = 1, lower = 2, both = 3
        var id: Int { rawValue }
    }

    var objectID: UInt64
    var axis: Axis = .z
    /// Coordonnée monde du plan sur l'axe (mm).
    var position: Double

    /// Plage de coupe utile : le plan doit traverser l'objet, avec 0,1 mm de marge.
    static func range(of instance: SceneInstance, axis: Axis) -> ClosedRange<Double>? {
        let lo = instance.min[axis.index] + 0.1, hi = instance.max[axis.index] - 0.1
        return lo < hi ? lo...hi : nil
    }

    /// Plan par défaut : au milieu de l'objet.
    static func centered(on object: SceneObject, axis: Axis = .z) -> CutPlane? {
        guard let inst = object.instances.first, range(of: inst, axis: axis) != nil else { return nil }
        return CutPlane(objectID: object.id, axis: axis, position: (inst.min[axis.index] + inst.max[axis.index]) / 2)
    }

    /// Un point du plan (repère monde) : le centre de l'objet, ramené sur le plan.
    func point(in instance: SceneInstance) -> [Double] {
        var p = zip(instance.min, instance.max).map { ($0 + $1) / 2 }
        p[axis.index] = position
        return p
    }

    func isValid(for instance: SceneInstance) -> Bool {
        Self.range(of: instance, axis: axis)?.contains(position) ?? false
    }

    /// Dimensions des deux moitiés le long de l'axe : (dessous, dessus).
    func halves(of instance: SceneInstance) -> (lower: Double, upper: Double) {
        (position - instance.min[axis.index], instance.max[axis.index] - position)
    }
}
