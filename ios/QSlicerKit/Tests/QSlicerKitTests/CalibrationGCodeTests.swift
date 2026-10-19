import XCTest
@testable import QSlicerKit

/// Pressure Advance (ligne, motif) et débit volumétrique maximal : mêmes recettes que le bureau,
/// vérifiées sur la vraie configuration d'un preset QIDI Q2.
final class CalibrationGCodeTests: XCTestCase {
    private func q2Config() throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "base_config", withExtension: "json", subdirectory: "Fixtures/engine"))
        return try SceneJSON.decodeDictionary(String(contentsOf: url, encoding: .utf8))
    }

    private func context() throws -> PAContext {
        try PAContext(config: q2Config(), bedCenter: [135, 135])
    }

    private func lines(_ g: String) -> [String] { g.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

    // MARK: Lecture de la configuration

    func testContextReadsPresetValues() throws {
        let c = try context()
        XCTAssertEqual(c.layerHeight, 0.2, accuracy: 1e-9)
        XCTAssertEqual(c.lineWidth, 0.42, accuracy: 1e-9)
        XCTAssertEqual(c.retractLength, 0.8, accuracy: 1e-9, "le filament n'a pas de valeur (nil) : celle de l'imprimante")
        XCTAssertEqual(c.retractSpeed, 30 * 60, accuracy: 1e-9)
        XCTAssertEqual(c.externalPerimeterAcceleration, 3000)
        XCTAssertEqual(c.maxFanSpeed, 255)
        XCTAssertTrue(c.sealPrint)
        // section d'extrusion : (0,42 − 0,2 × (1 − π/4)) × 0,2
        XCTAssertEqual(c.mm3PerMM, (0.42 - 0.2 * (1 - Double.pi / 4)) * 0.2, accuracy: 1e-12)
        XCTAssertEqual(c.ePerMM, c.mm3PerMM / (Double.pi * 0.875 * 0.875) * 0.98, accuracy: 1e-12)
    }

    func testPercentAndFallbackValues() throws {
        var config = try q2Config()
        config["first_layer_height"] = "150%"
        config["external_perimeter_extrusion_width"] = "0"
        config["extrusion_width"] = "0"
        let c = try PAContext(config: config, bedCenter: [135, 135])
        XCTAssertEqual(c.firstLayerHeight, 0.3, accuracy: 1e-9, "pourcentage de la hauteur de couche")
        XCTAssertEqual(c.lineWidth, 0.4 * 1.125, accuracy: 1e-9, "sans largeur configurée : 1,125 × la buse")
        XCTAssertThrowsError(try PAContext(config: ["nozzle_diameter": "0.4"], bedCenter: [0, 0]))
    }

    // MARK: Ligne

    func testPALineGCode() throws {
        let c = try context()
        let g = try CalibrationGCode.paLine(start: 0, end: 0.04, step: 0.002, context: c)
        XCTAssertEqual(g.values.count, 21)
        XCTAssertEqual(g.values.first, 0)
        XCTAssertEqual(g.values.last!, 0.04, accuracy: 1e-9)
        let l = lines(g.gcode)
        let ks = l.filter { $0.hasPrefix("M900 K") }.map { Double($0.dropFirst(6))! }
        XCTAssertEqual(ks.count, 22, "21 lignes + le retour à K = 0")
        XCTAssertEqual(ks.last, 0)
        XCTAssertEqual(Array(ks.dropLast()), g.values.map { Double(Calibration.format($0))! })
        XCTAssertTrue(l.contains("M204 S3000"), "accélération du périmètre externe")
        XCTAssertTrue(l.contains(";WIDTH:0.42"))
        XCTAssertTrue(g.gcode.hasSuffix(c.endGCode), "le G-code de fin de l'imprimante est conservé")
        XCTAssertEqual(g.size[0], 25)
        XCTAssertEqual(g.size[1], 20 * 4.62 + 0.42, accuracy: 1e-9)
        XCTAssertEqual(g.center, [85, 135])
        // chaque ligne : lente (1200), rapide (7200), lente
        XCTAssertEqual(l.filter { $0.hasSuffix(" F7200") && $0.hasPrefix("G1 X") }.count, 21 + 2)
        XCTAssertEqual(l.filter { $0.hasSuffix(" F1200") && $0.hasPrefix("G1 X") }.count, 21 * 2)
    }

    func testPALineCountIsCappedByTheBed() throws {
        let small = try PAContext(config: q2Config(), bedCenter: [50, 30])
        let g = try CalibrationGCode.paLine(start: 0, end: 1, step: 0.001, context: small)
        XCTAssertEqual(g.values.count, Int(30 / 4.62 * 2) - 4 + 1)
        XCTAssertThrowsError(try CalibrationGCode.paLine(start: 0.1, end: 0.05, step: 0.002, context: small))
        XCTAssertThrowsError(try CalibrationGCode.paLine(start: 0, end: 0.1, step: 0, context: small))
    }

    // MARK: Motif

    func testPAPatternGCode() throws {
        let c = try context()
        let g = try CalibrationGCode.paPattern(start: 0, end: 0.04, step: 0.004, context: c)
        XCTAssertEqual(g.values.count, 11)
        let l = lines(g.gcode)
        XCTAssertEqual(l.filter { $0.hasPrefix("M900 K") }.count, 11 * 4, "une fois par valeur et par couche (4 couches)")
        XCTAssertTrue(l.contains("M106 S255"))
        XCTAssertTrue(l.contains("M106 P2 S255"), "ventilateur auxiliaire (cloisonné)")
        XCTAssertTrue(l.contains("M106 P3 S255"))
        XCTAssertTrue(l.contains("M107") && l.contains("M106 P2 S0") && l.contains("M106 P3 S0"))
        // couche 1 à 0,2 mm puis couches 2, 3 et 4 à 0,4 / 0,6 / 0,8 mm
        for z in ["0.2", "0.4", "0.6", "0.8"] { XCTAssertTrue(l.contains("G0 Z\(z) F600"), "montée à Z = \(z)") }
        XCTAssertEqual(g.center, [104, 135])
        XCTAssertEqual(g.size[0], 25)
        XCTAssertEqual(g.size[2], 0.2, accuracy: 1e-9)
        XCTAssertTrue(g.gcode.hasSuffix(c.endGCode))
    }

    // MARK: Plans

    func testPAPlansReplaceEndGCodeAndPlaceTheBase() throws {
        let config = try q2Config()
        for kind in [CalibrationKind.pressureAdvanceLine(start: 0, end: 0.04, step: 0.002),
                     .pressureAdvancePattern(start: 0, end: 0.04, step: 0.002)] {
            let plan = try Calibration.plan(for: kind, base: config, maxPrintHeight: 260)
            XCTAssertEqual(plan.overrides["perimeter_generator"], "arachne")
            XCTAssertTrue(plan.overrides["end_gcode"]?.contains("M900 K") == true)
            XCTAssertEqual(plan.targetSize?.count, 3)
            XCTAssertEqual(plan.position?.count, 2)
            XCTAssertFalse(plan.legend.isEmpty)
        }
        let line = try Calibration.plan(for: .pressureAdvanceLine(start: 0, end: 0.04, step: 0.002), base: config, maxPrintHeight: 260)
        XCTAssertEqual(line.resource, "PressureAdvance/pa_line.stl")
        XCTAssertEqual(line.legend.first, "1 : K = 0")
        XCTAssertEqual(line.legend.count, 21)
        let pattern = try Calibration.plan(for: .pressureAdvancePattern(start: 0, end: 0.04, step: 0.002), base: config, maxPrintHeight: 260)
        XCTAssertEqual(pattern.resource, "PressureAdvance/pa_pattern.stl")
    }

    func testVolumetricSpeedPlanMatchesDesktopRecipe() throws {
        let config = try q2Config()
        let plan = try Calibration.plan(for: .maxVolumetricSpeed(start: 5, end: 20, step: 0.5), base: config, maxPrintHeight: 260)
        XCTAssertEqual(plan.resource, "VolumetricSpeed/volumetric_speed.stl")
        let layer = 0.4 * 0.8
        XCTAssertEqual(plan.overrides["layer_height"], "0.32")
        XCTAssertEqual(plan.overrides["perimeters"], "1")
        XCTAssertEqual(plan.overrides["fill_density"], "0%")
        XCTAssertEqual(plan.overrides["external_perimeter_extrusion_width"], "0.7")
        // 31 valeurs (5 → 20 par 0,5) : la première couche à la vitesse de départ, 30 plages ensuite
        XCTAssertEqual(plan.targetHeight!, 31 * layer, accuracy: 1e-9)
        XCTAssertEqual(plan.layerRanges.count, 30)
        let res = layer * (0.7 - layer * (1 - 0.25 * Double.pi))
        let first = plan.layerRanges[0]
        XCTAssertEqual(first.minZ, layer, accuracy: 1e-12)
        XCTAssertEqual(first.maxZ, 2 * layer, accuracy: 1e-12)
        XCTAssertEqual(first.key, "external_perimeter_speed")
        XCTAssertEqual(Double(first.value)!, (5 + 0.5) / res, accuracy: 1e-3)
        XCTAssertEqual(Double(plan.overrides["first_layer_speed"]!)!, 5 / res, accuracy: 1e-3)
        let last = plan.layerRanges[29]
        XCTAssertEqual(Double(last.value)!, (5 + 0.5 * 30) / res, accuracy: 1e-3)
        XCTAssertEqual(last.maxZ, 31 * layer, accuracy: 1e-9)
        // les plages ne se chevauchent pas
        for (a, b) in zip(plan.layerRanges, plan.layerRanges.dropFirst()) { XCTAssertLessThanOrEqual(a.maxZ, b.minZ + 1e-9) }
        XCTAssertNil(plan.targetSize, "plateau assez grand : modèle non élargi")
    }

    func testVolumetricSpeedPlanLimits() throws {
        let config = try q2Config()
        let tall = try Calibration.plan(for: .maxVolumetricSpeed(start: 1, end: 1000, step: 0.1), base: config, maxPrintHeight: 100)
        XCTAssertEqual(tall.targetHeight!, floor(100 / 0.32 + 0.0001) * 0.32, accuracy: 1e-9, "borné par la hauteur d'impression")
        let narrow = try Calibration.plan(for: .maxVolumetricSpeed(start: 5, end: 10, step: 1), base: config,
                                          maxPrintHeight: 260, bedSize: [150, 150])
        XCTAssertEqual(narrow.targetSize?[0], 145)
        XCTAssertThrowsError(try Calibration.plan(for: .maxVolumetricSpeed(start: 0, end: 10, step: 1), base: config, maxPrintHeight: 260))
        XCTAssertThrowsError(try Calibration.plan(for: .maxVolumetricSpeed(start: 5, end: 4, step: 1), base: config, maxPrintHeight: 260))
        XCTAssertThrowsError(try Calibration.plan(for: .maxVolumetricSpeed(start: 5, end: 10, step: 1), base: [:], maxPrintHeight: 260))
    }
}
