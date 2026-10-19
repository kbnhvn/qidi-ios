import XCTest
@testable import QSlicerKit

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
