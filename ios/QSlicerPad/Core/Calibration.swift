//
//  Calibration.swift
//  Impressions de calibration du menu « Calibration » de QIDISlicer : Pressure Advance
//  (tour, ligne, motif), débit (grossier / fin), débit volumétrique maximal. Reprend à l'identique la préparation de
//  Plater::calib_pa_tower / calib_flowrate_coarse / calib_flowrate_fine : modèle
//  fourni dans resources/calib, réglages temporaires et G-code de couche.
//  Pur Foundation : testé sous Linux.
//

import Foundation

enum CalibrationKind: Equatable {
    case pressureAdvanceTower(start: Double, end: Double, step: Double)
    case pressureAdvanceLine(start: Double, end: Double, step: Double)
    case pressureAdvancePattern(start: Double, end: Double, step: Double)
    case flowCoarse
    case flowFine(multiplier: Double)
    case maxVolumetricSpeed(start: Double, end: Double, step: Double)

    var title: String {
        switch self {
        case .pressureAdvanceTower: return "Pressure Advance (tour)"
        case .pressureAdvanceLine: return "Pressure Advance (ligne)"
        case .pressureAdvancePattern: return "Pressure Advance (motif)"
        case .maxVolumetricSpeed: return "Débit volumétrique maximal"
        case .flowCoarse: return "Débit — calibration grossière"
        case .flowFine: return "Débit — calibration fine"
        }
    }
}

struct CalibrationPlan: Equatable {
    /// Chemin du modèle sous `qidi/calib/`.
    let resource: String
    /// Réglages temporaires (clé .ini → valeur).
    let overrides: [String: String]
    /// Hauteur finale voulue du modèle (mm), nil = taille d'origine.
    let targetHeight: Double?
    let notice: String
    /// Dimensions voulues (x, y, z ; nil = inchangé) et position du centre (x, y) du modèle.
    var targetSize: [Double?]? = nil
    var position: [Double?]? = nil
    /// Plages de hauteurs à créer : (min, max, clé, valeur).
    var layerRanges: [LayerRange] = []
    /// Aide à la lecture du résultat (valeur de chaque ligne, formule…), affichée pendant la calibration.
    var legend: [String] = []

    struct LayerRange: Equatable {
        var minZ: Double
        var maxZ: Double
        var key: String
        var value: String
    }

    static let notice = "Les réglages de la calibration sont temporaires : notez la meilleure valeur, puis quittez la calibration pour retrouver vos réglages."
}

enum Calibration {
    enum PlanError: Error, Equatable {
        case invalidRange(String)
    }

    /// - Parameters:
    ///   - base: configuration effective actuelle (pour compléter `start_gcode`, `before_layer_gcode`).
    ///   - maxPrintHeight: hauteur maximale d'impression (mm).
    static func plan(for kind: CalibrationKind, base: [String: String], maxPrintHeight: Double,
                     bedCenter: [Double] = [135, 135], bedSize: [Double] = [270, 270]) throws -> CalibrationPlan {
        switch kind {
        case .pressureAdvanceLine(let start, let end, let step):
            let g = try CalibrationGCode.paLine(start: start, end: end, step: step,
                                                context: try PAContext(config: base, bedCenter: bedCenter))
            return paPlan(resource: "PressureAdvance/pa_line.stl", generation: g)

        case .pressureAdvancePattern(let start, let end, let step):
            let g = try CalibrationGCode.paPattern(start: start, end: end, step: step,
                                                   context: try PAContext(config: base, bedCenter: bedCenter))
            return paPlan(resource: "PressureAdvance/pa_pattern.stl", generation: g)

        case .maxVolumetricSpeed(let start, let end, let step):
            return try volumetricSpeedPlan(start: start, end: end, step: step, base: base,
                                           maxPrintHeight: maxPrintHeight, bedSize: bedSize)

        case .pressureAdvanceTower(let start, let end, let step):
            guard step > 0, end > start, start >= 0 else {
                throw PlanError.invalidRange("Valeurs attendues : début ≥ 0, fin > début, pas > 0.")
            }
            // Une marche de 5 mm par pas, bornée par la hauteur du plateau.
            let maxCount = (maxPrintHeight / 5 + 0.0001).rounded(.down) - 1
            let count = min(((end - start) / step + 0.0001).rounded(.down), maxCount)
            let gcode = "M900 K{int(layer_z / 5) * \(format(step)) + \(format(start))}\n" + (base["before_layer_gcode"] ?? "")
            return CalibrationPlan(resource: "PressureAdvance/pa_tower.stl",
                                   overrides: ["before_layer_gcode": gcode],
                                   targetHeight: (count + 1) * 5, notice: CalibrationPlan.notice)

        case .flowCoarse:
            return CalibrationPlan(resource: "FlowRate/flowrate_coarse.3mf",
                                   overrides: flowOverrides(base: base, startGCode: "\nM221 S120",
                                                            between: "M221 S{120 - 5 * current_object_idx}"),
                                   targetHeight: nil, notice: CalibrationPlan.notice)

        case .flowFine(let multiplier):
            guard multiplier > 0.5, multiplier < 1.5 else {
                throw PlanError.invalidRange("Multiplicateur d'extrusion attendu entre 0,5 et 1,5.")
            }
            let em = Int(multiplier * 100)
            return CalibrationPlan(resource: "FlowRate/flowrate_fine.3mf",
                                   overrides: flowOverrides(base: base, startGCode: "\nM221 S\(em + 4)",
                                                            between: "M221 S{ \(em + 4) - current_object_idx}"),
                                   targetHeight: nil, notice: CalibrationPlan.notice)
        }
    }

    private static func paPlan(resource: String, generation g: PAGeneration) -> CalibrationPlan {
        var plan = CalibrationPlan(resource: resource,
                                   overrides: ["perimeter_generator": "arachne", "end_gcode": g.gcode],
                                   targetHeight: nil, notice: CalibrationPlan.notice)
        plan.targetSize = g.size.map { Optional($0) }
        plan.position = g.center.map { Optional($0) }
        plan.legend = g.values.enumerated().map { "\($0.offset + 1) : K = \(format($0.element))" }
        return plan
    }

    /// Plater::calib_max_volumetric_speed : un mur d'un seul périmètre dont la vitesse du périmètre
    /// externe augmente de plage en plage (une plage = une couche), donc le débit aussi.
    private static func volumetricSpeedPlan(start: Double, end: Double, step: Double, base: [String: String],
                                            maxPrintHeight: Double, bedSize: [Double]) throws -> CalibrationPlan {
        guard step > 0, end > start, start > 0 else {
            throw PlanError.invalidRange("Valeurs attendues : début > 0, fin > début, pas > 0 (mm³/s).")
        }
        guard let nozzle = base["nozzle_diameter"].flatMap({ Double(OptionValue.first($0)) }), nozzle > 0 else {
            throw PlanError.invalidRange("Diamètre de buse introuvable.")
        }
        let layer = nozzle * 0.8
        let width = nozzle * 1.75
        let res = layer * (width - layer * (1 - 0.25 * Double.pi))
        let startSpeed = start / res, stepSpeed = step / res

        var count = ((end - start) / step + 1.0001).rounded(.down)
        let maxCount = (maxPrintHeight / layer + 0.0001).rounded(.down)
        count = min(count, maxCount)

        let overrides: [String: String] = [
            "resonance_avoidance": "0",
            "max_layer_height": format(layer),
            "layer_height": format(layer),
            "first_layer_height": format(layer),
            "perimeters": "1",
            "top_solid_layers": "0",
            "bottom_solid_layers": "0",
            "fill_density": "0%",
            "brim_width": "5",
            "brim_separation": "0",
            "first_layer_speed": format(startSpeed),
            "external_perimeter_extrusion_width": format(width),
            "first_layer_extrusion_width": format(width),
            "extrusion_multiplier": "1",
        ]
        // Mêmes plages que le bureau : la couche n (n ≥ 1) imprime à start + n × pas.
        var ranges: [CalibrationPlan.LayerRange] = []
        if count > 1 {
            for n in 1..<Int(count) {
                ranges.append(.init(minZ: layer * Double(n), maxZ: layer * Double(n + 1),
                                    key: "external_perimeter_speed", value: format(startSpeed + stepSpeed * Double(n))))
            }
        }
        var plan = CalibrationPlan(resource: "VolumetricSpeed/volumetric_speed.stl", overrides: overrides,
                                   targetHeight: count * layer, notice: CalibrationPlan.notice)
        plan.layerRanges = ranges
        if let width = bedSize.first, width < 180 { plan.targetSize = [width - 5, nil, count * layer] }
        plan.legend = [
            "Débit à la hauteur h (mm) ≈ \(format(start)) + \(format(step)) × (h / \(format(layer))) mm³/s",
            "Le mur est bon jusqu'à la hauteur où le périmètre devient irrégulier ou sous-extrudé.",
        ]
        return plan
    }

    private static func flowOverrides(base: [String: String], startGCode: String, between: String) -> [String: String] {
        [
            "complete_objects": "1",
            "extruder_clearance_radius": "1",
            "extrusion_multiplier": "1",
            "start_gcode": (base["start_gcode"] ?? "") + startGCode,
            "between_objects_gcode": between,
        ]
    }

    /// 0.04 → « 0.04 », 0.002 → « 0.002 » (pas de notation scientifique dans le gabarit).
    static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }
}
