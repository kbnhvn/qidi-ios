//
//  GCodeMesh.swift
//  Construit, à partir des mouvements fournis par le moteur (qsid_gcode_moves), la
//  géométrie de l'aperçu : rubans (largeur et hauteur réelles) groupés par couche,
//  colorés par type d'extrusion, vitesse, hauteur, largeur, ventilateur,
//  température ou débit volumique. Pur Foundation : testé sous Linux.
//

import Foundation
#if canImport(simd)
import simd
#endif

enum GCodeMoveType: UInt8 {
    case noop = 0, retract, unretract, seam, toolChange, colorChange, pause, customGCode, travel, wipe, extrude
}

/// Rôle d'extrusion, dans l'ordre de l'ABI (GCodeExtrusionRole du moteur).
enum GCodeRole: UInt8, CaseIterable {
    case none = 0, perimeter, externalPerimeter, overhangPerimeter, internalInfill, solidInfill,
         topSolidInfill, ironing, bridgeInfill, gapFill, skirt, supportMaterial,
         supportMaterialInterface, wipeTower, custom

    /// Libellé français (la légende du bureau, traduite).
    var label: String {
        switch self {
        case .none: return "Aucun"
        case .perimeter: return "Périmètre"
        case .externalPerimeter: return "Périmètre externe"
        case .overhangPerimeter: return "Périmètre en surplomb"
        case .internalInfill: return "Remplissage interne"
        case .solidInfill: return "Remplissage plein"
        case .topSolidInfill: return "Remplissage plein supérieur"
        case .ironing: return "Lissage"
        case .bridgeInfill: return "Pont"
        case .gapFill: return "Comblement"
        case .skirt: return "Jupe / bordure"
        case .supportMaterial: return "Supports"
        case .supportMaterialInterface: return "Interface de supports"
        case .wipeTower: return "Tour d'essuyage"
        case .custom: return "G-code personnalisé"
        }
    }

    /// Couleurs du bureau (PrusaSlicer/QIDISlicer).
    var rgb: (UInt8, UInt8, UInt8) {
        switch self {
        case .none: return (230, 179, 179)
        case .perimeter: return (255, 230, 77)
        case .externalPerimeter: return (255, 125, 56)
        case .overhangPerimeter: return (31, 31, 255)
        case .internalInfill: return (176, 48, 41)
        case .solidInfill: return (150, 84, 204)
        case .topSolidInfill: return (240, 64, 64)
        case .ironing: return (255, 140, 105)
        case .bridgeInfill: return (77, 128, 186)
        case .gapFill: return (255, 255, 255)
        case .skirt: return (0, 135, 110)
        case .supportMaterial: return (0, 255, 0)
        case .supportMaterialInterface: return (0, 128, 0)
        case .wipeTower: return (179, 227, 171)
        case .custom: return (94, 209, 148)
        }
    }
}

struct GCodeMove: Equatable {
    var x: Float, y: Float, z: Float
    var feedrate: Float, width: Float, height: Float
    var fanSpeed: Float, temperature: Float, time: Float, eDelta: Float
    var layer: UInt32
    var type: UInt8
    var role: UInt8

    var moveType: GCodeMoveType { GCodeMoveType(rawValue: type) ?? .noop }
    var extrusionRole: GCodeRole { GCodeRole(rawValue: role) ?? .none }
    var volumetricFlow: Float { feedrate * width * height }
}

enum GCodeColorMode: String, CaseIterable, Identifiable {
    case featureType, speed, height, width, fan, temperature, flow
    var id: String { rawValue }

    var label: String {
        switch self {
        case .featureType: return "Type"
        case .speed: return "Vitesse"
        case .height: return "Hauteur de couche"
        case .width: return "Largeur"
        case .fan: return "Ventilateur"
        case .temperature: return "Température"
        case .flow: return "Débit volumique"
        }
    }

    var unit: String {
        switch self {
        case .featureType: return ""
        case .speed: return "mm/s"
        case .height, .width: return "mm"
        case .fan: return "%"
        case .temperature: return "°C"
        case .flow: return "mm³/s"
        }
    }

    func value(of move: GCodeMove) -> Float {
        switch self {
        case .featureType: return Float(move.role)
        case .speed: return move.feedrate
        case .height: return move.height
        case .width: return move.width
        case .fan: return move.fanSpeed
        case .temperature: return move.temperature
        case .flow: return move.volumetricFlow
        }
    }
}

/// Dégradé bleu → cyan → vert → jaune → rouge (t de 0 à 1), comme les échelles du bureau.
func gcodeRangeColor(_ t: Float) -> (UInt8, UInt8, UInt8) {
    let stops: [(Float, Float, Float)] = [(0.043, 0.173, 0.478), (0.075, 0.349, 0.557), (0.110, 0.533, 0.569),
                                          (0.016, 0.839, 0.059), (0.667, 0.949, 0.000), (0.988, 0.976, 0.012),
                                          (0.961, 0.451, 0.024), (0.667, 0.121, 0.114)]
    let clamped = min(max(t, 0), 1) * Float(stops.count - 1)
    let i = min(Int(clamped), stops.count - 2)
    let f = clamped - Float(i)
    func mix(_ a: Float, _ b: Float) -> UInt8 { UInt8(((a + (b - a) * f) * 255).rounded()) }
    return (mix(stops[i].0, stops[i + 1].0), mix(stops[i].1, stops[i + 1].1), mix(stops[i].2, stops[i + 1].2))
}

struct GCodeLayerMesh {
    var z: Float = 0
    /// Triangles : positions xyz (3 floats/sommet), couleurs rgba (4 octets/sommet), indices.
    var positions: [Float] = []
    var colors: [UInt8] = []
    var indices: [UInt32] = []
    /// Déplacements à vide : paires de points xyz.
    var travel: [Float] = []
    /// Rétractions / reprises (points xyz), coutures.
    var retractions: [Float] = []
    var seams: [Float] = []
    var duration: Float = 0
}

struct GCodeMesh {
    var layers: [GCodeLayerMesh]
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    /// Plage de valeurs du mode scalaire (nil pour « type »).
    var valueRange: (min: Float, max: Float)?
    /// Rubans complets (haut + flancs) ou, au-delà du budget, face supérieure seule.
    var fullDetail: Bool
    /// Vrai si des remplissages internes ont été omis pour tenir dans le budget mémoire.
    var simplified: Bool

    var segmentCount: Int { layers.reduce(0) { $0 + $1.indices.count / (fullDetail ? 18 : 6) } }
}

struct GCodeMeshBuilder {
    var mode: GCodeColorMode = .featureType
    /// Au-delà, les rubans n'ont plus de flancs.
    var fullDetailBudget = 300_000
    /// Au-delà, on omet remplissages internes et pleins.
    var simplifyBudget = 1_500_000
    var includeTravel = true
    /// Rôles masqués (légende interactive).
    var hiddenRoles: Set<UInt8> = []

    func build(moves: [GCodeMove]) -> GCodeMesh {
        var extrusions = 0
        var maxLayer: UInt32 = 0
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var scalarLo = Float.greatestFiniteMagnitude, scalarHi = -Float.greatestFiniteMagnitude
        for m in moves {
            maxLayer = max(maxLayer, m.layer)
            guard m.moveType == .extrude else { continue }
            extrusions += 1
            if mode != .featureType {
                let v = mode.value(of: m)
                scalarLo = min(scalarLo, v); scalarHi = max(scalarHi, v)
            }
        }

        let full = extrusions <= fullDetailBudget
        let simplify = extrusions > simplifyBudget
        var layers = [GCodeLayerMesh](repeating: GCodeLayerMesh(), count: moves.isEmpty ? 0 : Int(maxLayer) + 1)

        var previous: SIMD3<Float>?
        for m in moves {
            let end = SIMD3<Float>(m.x, m.y, m.z)
            defer { previous = end }
            let li = Int(m.layer)
            guard li < layers.count else { continue }
            layers[li].duration += m.time

            switch m.moveType {
            case .extrude:
                layers[li].z = max(layers[li].z, m.z)
                guard let start = previous, !hiddenRoles.contains(m.role) else { continue }
                if simplify, m.extrusionRole == .internalInfill || m.extrusionRole == .solidInfill { continue }
                let dx = end.x - start.x, dy = end.y - start.y
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 1e-4, m.width > 0, m.height > 0 else { continue }
                let color = self.color(for: m, range: (scalarLo, scalarHi))
                Self.appendRibbon(&layers[li], from: start, to: end, dx: dx / length, dy: dy / length,
                                  width: m.width, height: m.height, color: color, full: full)
                lo = simd_min(lo, simd_min(start, end)); hi = simd_max(hi, simd_max(start, end))
            case .travel where includeTravel:
                if let start = previous {
                    layers[li].travel += [start.x, start.y, start.z, end.x, end.y, end.z]
                }
            case .retract, .unretract:
                layers[li].retractions += [end.x, end.y, end.z]
            case .seam:
                layers[li].seams += [end.x, end.y, end.z]
            default:
                break
            }
        }

        if lo.x > hi.x { lo = .zero; hi = .zero }
        return GCodeMesh(layers: layers, boundsMin: lo, boundsMax: hi,
                         valueRange: mode == .featureType || scalarLo > scalarHi ? nil : (scalarLo, scalarHi),
                         fullDetail: full, simplified: simplify)
    }

    private func color(for move: GCodeMove, range: (Float, Float)) -> (UInt8, UInt8, UInt8) {
        if mode == .featureType { return move.extrusionRole.rgb }
        let span = range.1 - range.0
        return gcodeRangeColor(span > 1e-6 ? (mode.value(of: move) - range.0) / span : 0.5)
    }

    private static func appendRibbon(_ layer: inout GCodeLayerMesh, from a: SIMD3<Float>, to b: SIMD3<Float>,
                                     dx: Float, dy: Float, width: Float, height: Float,
                                     color: (UInt8, UInt8, UInt8), full: Bool) {
        let nx = -dy * width / 2, ny = dx * width / 2
        let zTop = b.z, zBottom = b.z - height
        func vertex(_ p: SIMD3<Float>, _ sx: Float, _ z: Float, shade: Float) -> UInt32 {
            let index = UInt32(layer.positions.count / 3)
            layer.positions += [p.x + nx * sx, p.y + ny * sx, z]
            layer.colors += [UInt8(Float(color.0) * shade), UInt8(Float(color.1) * shade), UInt8(Float(color.2) * shade), 255]
            return index
        }
        // face supérieure
        let t0 = vertex(a, 1, zTop, shade: 1), t1 = vertex(a, -1, zTop, shade: 1)
        let t2 = vertex(b, -1, zTop, shade: 1), t3 = vertex(b, 1, zTop, shade: 1)
        layer.indices += [t0, t1, t2, t0, t2, t3]
        guard full else { return }
        // flancs
        let l0 = vertex(a, 1, zBottom, shade: 0.7), l3 = vertex(b, 1, zBottom, shade: 0.7)
        layer.indices += [t0, l0, l3, t0, l3, t3]
        let r1 = vertex(a, -1, zBottom, shade: 0.7), r2 = vertex(b, -1, zBottom, shade: 0.7)
        layer.indices += [t1, t2, r2, t1, r2, r1]
    }
}
