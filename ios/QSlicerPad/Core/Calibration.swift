//
//  Calibration.swift
//  Impressions de calibration du menu « Calibration » de QIDISlicer : tour de
//  Pressure Advance, débit (grossier / fin). Reprend à l'identique la préparation de
//  Plater::calib_pa_tower / calib_flowrate_coarse / calib_flowrate_fine : modèle
//  fourni dans resources/calib, réglages temporaires et G-code de couche.
//  Pur Foundation : testé sous Linux.
//

import Foundation

enum CalibrationKind: Equatable {
    case pressureAdvanceTower(start: Double, end: Double, step: Double)
    case flowCoarse
    case flowFine(multiplier: Double)

    var title: String {
        switch self {
        case .pressureAdvanceTower: return "Pressure Advance (tour)"
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

    static let notice = "Les réglages de la calibration sont temporaires : notez la meilleure valeur, puis quittez la calibration pour retrouver vos réglages."
}

enum Calibration {
    enum PlanError: Error, Equatable {
        case invalidRange(String)
    }

    /// - Parameters:
    ///   - base: configuration effective actuelle (pour compléter `start_gcode`, `before_layer_gcode`).
    ///   - maxPrintHeight: hauteur maximale d'impression (mm).
    static func plan(for kind: CalibrationKind, base: [String: String], maxPrintHeight: Double) throws -> CalibrationPlan {
        switch kind {
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
