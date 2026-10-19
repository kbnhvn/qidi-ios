//
//  CalibrationGCode.swift
//  G-code des calibrations « Pressure Advance — ligne » et « — motif », et plan de la
//  calibration de débit volumétrique maximal. Reprend Plater::calib_pa_line /
//  calib_pa_pattern / calib_max_volumetric_speed : un modèle de base est imprimé en
//  première couche, puis le G-code généré (qui remplace le G-code de fin de l'imprimante)
//  trace les lignes en changeant le Pressure Advance (M900 K…).
//  Les étiquettes numériques du bureau (maillage de texte) ne sont pas reproduites : l'app
//  affiche la valeur de chaque ligne dans l'ordre.
//  Pur Foundation : testé sous Linux.
//

import Foundation

/// Valeurs de la configuration effective nécessaires aux générateurs.
struct PAContext: Equatable {
    var bedCenter: [Double]
    var layerHeight: Double
    var firstLayerHeight: Double
    var nozzle: Double
    var lineWidth: Double
    var firstLayerTravelSpeed: Double      // mm/s
    var travelSpeed: Double                // mm/s
    var perimeterSpeed: Double
    var externalPerimeterSpeed: Double
    var firstLayerSpeed: Double
    var externalPerimeterAcceleration: Double
    var retractLength: Double
    var retractSpeed: Double               // mm/min
    var retractLift: Double
    var filamentDiameter: Double
    var extrusionMultiplier: Double
    var zOffset: Double
    var maxFanSpeed: Int
    var sealPrint: Bool
    var auxiliaryFan: Int
    var auxiliaryFanUnseal: Int
    var volumeFan: Int
    var endGCode: String

    /// mm³ d'extrusion par mm de ligne (section en « rectangle arrondi », comme Flow du moteur).
    var mm3PerMM: Double { (lineWidth - layerHeight * (1 - Double.pi / 4)) * layerHeight }
    var ePerMM: Double { mm3PerMM / (Double.pi * pow(filamentDiameter / 2, 2)) * extrusionMultiplier }

    /// Lit la configuration effective (valeurs .ini textuelles).
    init(config c: [String: String], bedCenter: [Double]) throws {
        func first(_ key: String) -> String? {
            guard let raw = c[key] else { return nil }
            let v = OptionValue.first(raw).trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v == "nil" ? nil : v
        }
        func number(_ key: String, _ fallback: Double? = nil) throws -> Double {
            if let v = first(key), let n = Double(v) { return n }
            if let fallback { return fallback }
            throw Calibration.PlanError.invalidRange("Réglage \(key) introuvable dans la configuration.")
        }
        /// « 0.4 » ou « 150% » (pourcentage de `over`).
        func absolute(_ key: String, over: Double) -> Double? {
            guard let v = first(key), let (n, percent) = OptionValue.numberAndPercent(v) else { return nil }
            return percent ? n * over / 100 : n
        }

        self.bedCenter = bedCenter
        layerHeight = try number("layer_height")
        nozzle = try number("nozzle_diameter")
        firstLayerHeight = absolute("first_layer_height", over: layerHeight) ?? layerHeight
        let widthExternal = absolute("external_perimeter_extrusion_width", over: layerHeight) ?? 0
        let widthDefault = absolute("extrusion_width", over: layerHeight) ?? 0
        lineWidth = widthExternal != 0 ? widthExternal : (widthDefault != 0 ? widthDefault : nozzle * 1.125)
        firstLayerTravelSpeed = try number("first_layer_travel_speed", 50)
        travelSpeed = try number("travel_speed", 120)
        perimeterSpeed = try number("perimeter_speed", 60)
        externalPerimeterSpeed = absolute("external_perimeter_speed", over: perimeterSpeed) ?? perimeterSpeed
        firstLayerSpeed = absolute("first_layer_speed", over: perimeterSpeed) ?? perimeterSpeed
        externalPerimeterAcceleration = absolute("external_perimeter_acceleration", over: 0) ?? 0
        // rétraction : réglage du filament s'il existe, sinon celui de l'imprimante
        retractLength = try number("filament_retract_length", try number("retract_length", 0))
        retractSpeed = (try number("filament_retract_speed", try number("retract_speed", 40))) * 60
        retractLift = try number("filament_retract_lift", try number("retract_lift", 0))
        filamentDiameter = try number("filament_diameter", 1.75)
        extrusionMultiplier = try number("extrusion_multiplier", 1)
        zOffset = try number("z_offset", 0)
        maxFanSpeed = Int((try number("max_fan_speed", 100) * 2.55).rounded())
        sealPrint = OptionValue.isTrue(first("seal_print") ?? "0")
        auxiliaryFan = Int((try number("enable_auxiliary_fan", 0) * 2.55).rounded())
        auxiliaryFanUnseal = Int((try number("enable_auxiliary_fan_unseal", 0) * 2.55).rounded())
        volumeFan = Int((try number("enable_volume_fan", 0) * 2.55).rounded())
        endGCode = c["end_gcode"] ?? ""
    }
}

/// Résultat d'un générateur : G-code, taille et position du modèle de base, valeurs par ligne.
struct PAGeneration: Equatable {
    var gcode: String
    /// Dimensions voulues du modèle de base (x, y, z) et position de son centre (x, y).
    var size: [Double]
    var center: [Double]
    /// Valeur de PA de chaque ligne, dans l'ordre d'impression (de bas en haut sur le plateau).
    var values: [Double]
}

enum CalibrationGCode {
    // MARK: Primitives de G-code (formats identiques au bureau)

    static func number(_ v: Double) -> String { Calibration.format(v) }

    static func moveRetracted(_ x: Double, _ y: Double, speed: Double, retract: Double, retractSpeed: Double) -> String {
        "\nG1 E\(number(-retract)) F\(number(retractSpeed))\nG0 X\(number(x)) Y\(number(y)) F\(number(speed))\nG1 E\(number(retract)) F\(number(retractSpeed))"
    }

    static func moveLifted(_ x: Double, _ y: Double, speed: Double, retract: Double, retractSpeed: Double,
                           height: Double, lift: Double) -> String {
        "\nG1 E\(number(-retract)) F\(number(retractSpeed))\nG0 Z\(number(height + lift)) F600\nG0 X\(number(x)) Y\(number(y)) F\(number(speed))\nG0 Z\(number(height)) F600\nG1 E\(number(retract)) F\(number(retractSpeed))"
    }

    static func extrude(_ x: Double, _ y: Double, speed: Double, e: Double) -> String {
        "\nG1 X\(number(x)) Y\(number(y)) E\(number(e)) F\(number(speed))"
    }

    static func moveZ(_ z: Double) -> String { "\nG0 Z\(number(z)) F600" }
    static func setPA(_ k: Double) -> String { "\nM900 K\(number(k))" }
    static func setAcceleration(_ a: Double) -> String { a > 0 ? "\nM204 S\(number(a))" : "" }

    /// Nombre de lignes : (fin − début) / pas, comme le bureau (la dernière valeur est incluse).
    static func steps(start: Double, end: Double, step: Double) throws -> Int {
        guard step > 0, end > start, start >= 0 else {
            throw Calibration.PlanError.invalidRange("Valeurs attendues : début ≥ 0, fin > début, pas > 0.")
        }
        return Int((end - start) / step + 0.0001)
    }

    // MARK: Ligne

    static func paLine(start: Double, end: Double, step: Double, context c: PAContext) throws -> PAGeneration {
        var count = try steps(start: start, end: end, step: step)
        let spacing = 4.62
        let maxCount = Int(c.bedCenter[1] / spacing * 2) - 4
        count = min(count, max(maxCount, 1))

        let startX = c.bedCenter[0] - 38, startY = c.bedCenter[1] - Double(count) * spacing / 2
        let fast = 7200.0, slow = 1200.0, short = 20.0, long = 40.0
        let travel = c.firstLayerTravelSpeed * 60
        let e = c.ePerMM
        let layer = c.layerHeight

        var g = "\n;WIDTH:\(number(c.lineWidth))"
        g += setAcceleration(c.externalPerimeterAcceleration)
        g += moveRetracted(startX + 80, startY, speed: travel, retract: c.retractLength, retractSpeed: c.retractSpeed)
        g += moveZ(layer + c.zOffset)
        g += extrude(startX + 80, startY + Double(count) * spacing, speed: 3000, e: Double(count) * spacing * e)

        var values: [Double] = []
        for i in 0...count {
            let k = start + Double(i) * step
            values.append(k)
            let y = startY + Double(i) * spacing
            g += setPA(k)
            g += moveRetracted(startX, y, speed: travel, retract: c.retractLength, retractSpeed: c.retractSpeed)
            g += extrude(startX + short, y, speed: slow, e: short * e)
            g += extrude(startX + short + long, y, speed: fast, e: long * e)
            g += extrude(startX + short + long + short, y, speed: slow, e: short * e)
        }

        let endY = startY + Double(count) * spacing
        g += setPA(0)
        g += moveRetracted(startX + short, endY + 1, speed: travel, retract: c.retractLength, retractSpeed: c.retractSpeed)
        g += extrude(startX + short, endY + 3, speed: fast, e: 2 * e)
        g += moveRetracted(startX + short + long, endY + 1, speed: travel, retract: c.retractLength, retractSpeed: c.retractSpeed)
        g += extrude(startX + short + long, endY + 3, speed: fast, e: 2 * e)
        g += "\n" + c.endGCode

        return PAGeneration(gcode: g, size: [25, Double(count) * spacing + c.lineWidth, c.firstLayerHeight],
                            center: [c.bedCenter[0] - 50, c.bedCenter[1]], values: values)
    }

    // MARK: Motif

    static func paPattern(start: Double, end: Double, step: Double, context c: PAContext) throws -> PAGeneration {
        var count = try steps(start: start, end: end, step: step)
        let spacing = 4.62
        let lineSpacing = c.lineWidth - c.layerHeight * (1 - Double.pi / 4)
        let lineSpacingXY = lineSpacing * 1.4142
        let wall = 38 - lineSpacing
        let maxCount = Int((c.bedCenter[1] * 2 - wall / 2) / spacing) - 4
        count = min(count, max(maxCount, 1))
        let wallWidth = Double(count + 1) * spacing + wall / 2 + 3 * lineSpacing

        let startX = c.bedCenter[0] - wall / 2, startY = c.bedCenter[1] + wallWidth / 2
        let travel = c.travelSpeed * 60
        let fast = c.externalPerimeterSpeed * 60
        let first = c.firstLayerSpeed * 60
        let e = c.ePerMM
        let layer = c.layerHeight
        let z0 = layer + c.zOffset
        let r = c.retractLength, rs = c.retractSpeed

        var g = "\n;WIDTH:\(number(c.lineWidth))"
        g += setAcceleration(c.externalPerimeterAcceleration)
        g += moveRetracted(startX + 2 * lineSpacing, startY - 2 * lineSpacing, speed: travel, retract: r, retractSpeed: rs)
        g += moveZ(z0)

        // cadre
        for i in 0..<3 {
            let d = Double(2 - i), d1 = Double(1 - i)
            g += extrude(startX + wall - d * lineSpacing, startY - d * lineSpacing, speed: first, e: (wall - 2 * d * lineSpacing) * e)
            g += extrude(startX + wall - d * lineSpacing, startY - wallWidth + d * lineSpacing, speed: first,
                         e: (Double(count + 1) * spacing + wall / 2 - 2 * d1 * lineSpacing) * e)
            g += extrude(startX + d * lineSpacing, startY - wallWidth + d * lineSpacing, speed: first, e: (wall - 2 * d * lineSpacing) * e)
            g += extrude(startX + d * lineSpacing, startY - d1 * lineSpacing, speed: first,
                         e: (Double(count + 1) * spacing + wall / 2 - 2 * d1 * lineSpacing) * e)
        }

        // première couche : trois chevrons par valeur
        var values: [Double] = []
        for n in 1...(count + 1) {
            let k = start + Double(n - 1) * step
            values.append(k)
            g += setPA(k)
            for i in 0..<3 {
                let dy = Double(n) * spacing + Double(i) * lineSpacingXY
                g += moveLifted(startX + 3 * lineSpacing, startY - dy, speed: travel, retract: r, retractSpeed: rs, height: z0, lift: c.retractLift)
                g += extrude(startX + wall / 2, startY - dy - wall / 2 + 3 * lineSpacing, speed: first,
                             e: (wall - 6 * lineSpacing) / 1.4142 * e)
                g += extrude(startX + wall - 3 * lineSpacing, startY - dy, speed: first, e: (wall - 6 * lineSpacing) / 1.4142 * e)
            }
        }

        // ventilateurs puis couches 2 à 4 à pleine vitesse
        g += "\nM106 S\(c.maxFanSpeed)"
        g += "\nM106 P2 S\(c.sealPrint ? c.auxiliaryFan : c.auxiliaryFanUnseal)"
        g += "\nM106 P3 S\(c.volumeFan)"
        for m in 2...4 {
            let z = layer * Double(m) + c.zOffset
            g += moveZ(z)
            for n in 1...(count + 1) {
                g += setPA(start + Double(n - 1) * step)
                for i in 0..<3 {
                    let dy = Double(n) * spacing + Double(i) * lineSpacingXY
                    g += moveLifted(startX, startY - dy + 3 * lineSpacing, speed: travel, retract: r, retractSpeed: rs, height: z, lift: c.retractLift)
                    g += extrude(startX + wall / 2, startY - dy - wall / 2 + 3 * lineSpacing, speed: fast, e: wall / 1.4142 * e)
                    g += extrude(startX + wall, startY - dy + 3 * lineSpacing, speed: fast, e: wall / 1.4142 * e)
                }
            }
        }
        g += "\nM107\nM106 P2 S0\nM106 P3 S0\n" + c.endGCode

        return PAGeneration(gcode: g, size: [25, wallWidth + lineSpacing, c.firstLayerHeight],
                            center: [c.bedCenter[0] - 31, c.bedCenter[1]], values: values)
    }
}
