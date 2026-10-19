import XCTest
@testable import QSlicerKit

final class ProfilesTests: XCTestCase {
    private func miniCatalog() throws -> QIDIProfileCatalog {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mini", withExtension: "ini", subdirectory: "Fixtures"))
        return QIDIProfileCatalog.parse(try String(contentsOf: url, encoding: .utf8))
    }

    func testListsConcretePresetsOnly() throws {
        let c = try miniCatalog()
        XCTAssertEqual(c.vendorName, "QIDI Technology")
        XCTAssertEqual(c.printers, ["Q2 0.4 nozzle", "Q2 0.6 nozzle"])
        XCTAssertFalse(c.printPresets.contains { $0.hasPrefix("*") })
    }

    func testPresetsFollowPrinterSuffix() throws {
        let c = try miniCatalog()
        XCTAssertEqual(Set(c.printPresets(for: "Q2 0.4 nozzle").prefix(2)),
                       ["0.20mm Standard @Q2 0.4 nozzle", "0.12mm Fine @Q2 0.4 nozzle"])
        XCTAssertEqual(c.filamentPresets(for: "Q2 0.6 nozzle").first, "QIDI PETG @Q2 0.6 nozzle")
    }

    func testInheritanceChainsAndSeparators() throws {
        let c = try miniCatalog()
        let cfg = c.resolvedConfig(printer: "Q2 0.6 nozzle",
                                   print: "0.12mm Fine @Q2 0.4 nozzle",
                                   filament: "QIDI ABS @Q2 0.4 nozzle")
        XCTAssertEqual(cfg["nozzle_diameter"], "0.6")          // surcharge de la variante
        XCTAssertEqual(cfg["use_relative_e_distances"], "1")   // hérité de *common* via *Q2*
        XCTAssertEqual(cfg["layer_height"], "0.12")
        XCTAssertEqual(cfg["temperature"], "260,260")
        XCTAssertNil(cfg["inherits"])
    }
}

final class OverridesTests: XCTestCase {
    private let base: [String: String] = [
        "layer_height": "0.2", "perimeters": "2", "fill_density": "15%",
        "brim_width": "0", "raft_layers": "0", "support_material": "0",
        "support_material_auto": "1", "support_material_buildplate_only": "0",
        "nozzle_diameter": "0.4", "temperature": "260,260", "first_layer_temperature": "265",
    ]

    func testNothingTouchedWritesNothing() {
        let o = SliceOverrides()
        XCTAssertTrue(o.isEmpty)
        XCTAssertEqual(o.configEntries(basedOn: base), [:])
        XCTAssertNil(o.summary(base: base))
    }

    func testValueEqualToPresetIsNotRetained() {
        var o = SliceOverrides()
        o.setInfillPercent(15, base: base)
        o.set("layer_height", "0.20", base: base)
        XCTAssertTrue(o.isEmpty)
        o.setInfillPercent(20, base: base)
        XCTAssertEqual(o.configEntries(basedOn: base), ["fill_density": "20%"])
        XCTAssertTrue(o.isModified("fill_density"))
        o.reset("fill_density")
        XCTAssertTrue(o.isEmpty)
    }

    func testSupportModesMatchDesktopSemantics() {
        var o = SliceOverrides()
        o.setSupportMode(.buildPlateOnly, base: base)
        XCTAssertEqual(o.supportMode(base: base), .buildPlateOnly)
        XCTAssertEqual(o.configEntries(basedOn: base)["support_material_buildplate_only"], "1")
        o.setSupportMode(.enforcersOnly, base: base)
        let e = o.configEntries(basedOn: base)
        XCTAssertEqual(e["support_material"], "1")
        XCTAssertEqual(e["support_material_auto"], "0")
        XCTAssertEqual(o.supportMode(base: base), .enforcersOnly)
        o.setSupportMode(.everywhere, base: base)
        XCTAssertEqual(o.supportMode(base: base), .everywhere)
        o.setSupportMode(.none, base: base)
        XCTAssertEqual(o.supportMode(base: base), .none)
    }

    func testAdhesionIsExclusiveAndOnlyTouchesItsKeys() {
        var o = SliceOverrides()
        o.setAdhesion(.brim, base: base)
        var e = o.configEntries(basedOn: base)
        XCTAssertEqual(e["brim_width"], "5")
        XCTAssertNil(e["raft_layers"])          // déjà 0 dans le preset
        XCTAssertNil(e["fill_density"])         // rien d'autre n'est imposé
        o.setAdhesion(.raft, base: base)
        e = o.configEntries(basedOn: base)
        XCTAssertEqual(e["raft_layers"], "3")
        XCTAssertNil(e["brim_width"])
        XCTAssertEqual(o.adhesion(base: base), .raft)
        o.setAdhesion(.none, base: base)
        XCTAssertTrue(o.isEmpty)
    }

    func testNozzleDeltaHandlesPerExtruderValues() {
        var o = SliceOverrides()
        o.nozzleDelta = 10
        let e = o.configEntries(basedOn: base)
        XCTAssertEqual(e["temperature"], "270,270")
        XCTAssertEqual(e["first_layer_temperature"], "275")
        XCTAssertEqual(o.configEntries(basedOn: [:]), [:])    // pas de base : ignoré
    }

    func testLayerHeightChoicesRespectNozzle() {
        XCTAssertFalse(SliceOverrides.layerHeightChoices(base: base).contains(0.36))   // > 75 % de 0,4 mm
        XCTAssertTrue(SliceOverrides.layerHeightChoices(base: base).contains(0.2))
        var fine = base; fine["nozzle_diameter"] = "0.2"; fine["layer_height"] = "0.1"
        XCTAssertEqual(SliceOverrides.layerHeightChoices(base: fine).max(), 0.15)
        var odd = base; odd["layer_height"] = "0.07"
        XCTAssertTrue(SliceOverrides.layerHeightChoices(base: odd).contains(0.07))
    }

    func testLegacyPersistedStateDecodesToEmpty() throws {
        let legacy = #"{"enabled":true,"adhesion":"brim","brimWidth":5,"supports":true,"infillDensity":15}"#
        let o = try JSONDecoder().decode(SliceOverrides.self, from: Data(legacy.utf8))
        XCTAssertTrue(o.isEmpty)
        var n = SliceOverrides(); n.setInfillPercent(30, base: base)
        let round = try JSONDecoder().decode(SliceOverrides.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(round, n)
    }

    func testSummaryListsOnlyWhatChanged() {
        var o = SliceOverrides()
        o.setSupportMode(.everywhere, base: base)
        o.setInfillPercent(25, base: base)
        o.set("seam_position", "random", base: base)
        let s = o.summary(base: base) ?? ""
        XCTAssertTrue(s.contains("supports") && s.contains("remplissage 25 %") && s.contains("1 autre"), s)
        XCTAssertFalse(s.contains("couche"))
    }
}

/// Contre le vrai bundle vendor (QSID_PROFILES_INI, ou third_party/ après bootstrap).
final class RealBundleTests: XCTestCase {
    private func realCatalog() throws -> QIDIProfileCatalog {
        let candidates = [
            ProcessInfo.processInfo.environment["QSID_PROFILES_INI"],
            "../../third_party/qidislicer/resources/profiles/QIDITechnology.ini",
            "/home/user/qiditech/qidislicer/resources/profiles/QIDITechnology.ini",
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("bundle QIDITechnology.ini absent (QSID_PROFILES_INI)")
        }
        return QIDIProfileCatalog.parse(try String(contentsOfFile: path, encoding: .utf8))
    }

    func testCountsMatchDocumentedBundle() throws {
        let c = try realCatalog()
        XCTAssertEqual(c.printers.count, 24)
        XCTAssertEqual(c.printPresets.count, 78)
        XCTAssertEqual(c.filamentPresets.count, 858)
    }

    func testEveryPrinterHasCompatiblePrintAndFilament() throws {
        let c = try realCatalog()
        for printer in c.printers {
            let prints = c.printPresets(for: printer)
            let filaments = c.filamentPresets(for: printer)
            XCTAssertFalse(prints.isEmpty, printer)
            XCTAssertFalse(filaments.isEmpty, printer)
            // Aucun preset d'une autre variante de buse en tête de liste.
            XCTAssertTrue(prints[0].hasSuffix("@" + printer), "\(printer) → \(prints[0])")
            XCTAssertTrue(filaments[0].hasSuffix("@" + printer), "\(printer) → \(filaments[0])")
            let cfg = c.resolvedConfig(printer: printer, print: prints[0], filament: filaments[0])
            XCTAssertEqual(cfg["use_relative_e_distances"], "1", printer)
            XCTAssertNotNil(cfg["bed_shape"], printer)
            XCTAssertNotNil(Double(cfg["layer_height"] ?? ""), printer)
        }
    }

    func testLayerHeightChoicesForEveryNozzle() throws {
        let c = try realCatalog()
        for printer in c.printers {
            let cfg = c.resolvedConfig(printer: printer, print: c.printPresets(for: printer)[0], filament: nil)
            let choices = SliceOverrides.layerHeightChoices(base: cfg)
            XCTAssertFalse(choices.isEmpty, printer)
            let nozzle = SliceOverrides.nozzleDiameter(base: cfg)
            XCTAssertTrue(choices.dropLast().allSatisfy { $0 <= nozzle }, printer)
        }
    }
}
