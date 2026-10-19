import XCTest
@testable import QSlicerKit

/// Décode des sorties *réelles* du moteur (ABI v3), capturées avec le vrai bundle QIDI :
/// toute dérive entre le JSON du C++ et les types Swift est détectée ici, sous Linux.
final class EngineJSONTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/engine"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSceneInfo() throws {
        let info = try SceneJSON.decode(SceneInfo.self, from: fixture("scene_info"))
        XCTAssertEqual(info.bed.width, 270)
        XCTAssertEqual(info.bed.depth, 270)
        XCTAssertEqual(info.bed.maxHeight, 260)
        XCTAssertEqual(info.objects.count, 2)
        let first = try XCTUnwrap(info.objects.first)
        XCTAssertEqual(first.name, "cube_20mm.stl")
        XCTAssertEqual(first.triangles, 12)
        XCTAssertEqual(first.localSize, [20, 20, 20])
        let i = try XCTUnwrap(first.instances.first)
        XCTAssertEqual(i.matrix.count, 16)
        XCTAssertEqual(i.size, [20, 20, 20])
        XCTAssertEqual(i.min[2], 0, "posé sur le plateau")
        XCTAssertFalse(info.hasObjectOutsideBed)
        // deux objets distincts, sans chevauchement en XY
        let a = info.objects[0].instances[0], b = info.objects[1].instances[0]
        XCTAssertTrue(a.max[0] <= b.min[0] || b.max[0] <= a.min[0] || a.max[1] <= b.min[1] || b.max[1] <= a.min[1])
    }

    func testAddResultAndPresetSelection() throws {
        let added = try SceneJSON.decode(SceneAddResult.self, from: fixture("add_result"))
        XCTAssertEqual(added.added.count, 1)
        XCTAssertTrue(added.alerts.isEmpty)
        let selection = try SceneJSON.decodeDictionary(fixture("select"))
        XCTAssertEqual(selection["printer"], "Q2 0.4 nozzle")
        XCTAssertTrue(selection["print"]?.hasPrefix("0.20mm") == true)
    }

    func testSliceSummary() throws {
        let s = try SceneJSON.decode(SliceSummary.self, from: fixture("summary"))
        XCTAssertEqual(s.layers, 100)
        XCTAssertGreaterThan(s.timeNormalS, 60)
        XCTAssertGreaterThan(s.filamentG, 1)
        XCTAssertFalse(s.roles.isEmpty)
        XCTAssertTrue(s.roles.contains { $0.name == "external_perimeter" })
        XCTAssertTrue(s.warnings.isEmpty)
        // les rôles du résumé correspondent à l'énumération Swift (même ordre que l'ABI)
        for role in s.roles { XCTAssertNotNil(GCodeRole(rawValue: UInt8(role.role)), role.name) }
        XCTAssertEqual(GCodeRole(rawValue: 2), .externalPerimeter)
        XCTAssertEqual(formatDuration(seconds: 1039), "17 min")
        XCTAssertEqual(formatDuration(seconds: 3900), "1 h 05 min")
    }

    func testConfigDictionaries() throws {
        let base = try SceneJSON.decodeDictionary(fixture("base_config"))
        XCTAssertEqual(base["use_relative_e_distances"], "1")
        XCTAssertEqual(base["gcode_flavor"], "klipper")
        XCTAssertEqual(base["printer_model"], "Q2")
        XCTAssertNotNil(Double(base["layer_height"] ?? ""))
        XCTAssertEqual(try SceneJSON.decodeDictionary(fixture("overrides")), ["fill_density": "25%"])
        // les valeurs que SliceOverrides lit existent bien dans la config du moteur
        for key in ["fill_density", "layer_height", "perimeters", "brim_width", "raft_layers", "support_material",
                    "support_material_auto", "support_material_buildplate_only", "temperature",
                    "first_layer_temperature", "nozzle_diameter", "max_print_height"] {
            XCTAssertNotNil(base[key], key)
        }
        // le résumé et les modes lisent la config réelle sans surprise
        var o = SliceOverrides()
        o.setInfillPercent(25, base: base)
        XCTAssertEqual(o.configEntries(basedOn: base), ["fill_density": "25%"])
        XCTAssertEqual(o.infillPercent(base: base), 25)
        XCTAssertEqual(SliceOverrides.nozzleDiameter(base: base), 0.4)
        XCTAssertTrue(SliceOverrides.layerHeightChoices(base: base).contains(0.2))
    }

    func testFilamentListGroupingWithEngineOutput() throws {
        let presets = try SceneJSON.decodeStrings(fixture("filaments"))
        XCTAssertGreaterThan(presets.count, 100, "le moteur liste toutes les variantes de buse du modèle")
        let mine = FilamentIndex.forPrinter(presets, printer: "Q2 0.4 nozzle")
        XCTAssertTrue(mine.allSatisfy { $0.hasSuffix("@Q2 0.4 nozzle") })
        XCTAssertGreaterThan(mine.count, 30)
        XCTAssertLessThan(mine.count, presets.count)
        XCTAssertTrue(FilamentIndex.preferredDefault(mine)?.hasPrefix("QIDI PLA") == true)
        let groups = FilamentIndex.grouped(FilamentIndex.entries(mine))
        XCTAssertEqual(groups.first?.material, "PLA")
        XCTAssertFalse(groups.contains { $0.material == "Autre" })
    }
}

final class SettingsCatalogTests: XCTestCase {
    private func catalog(french: Bool = true) throws -> SettingsCatalog {
        let engine = try XCTUnwrap(Bundle.module.url(forResource: "schema", withExtension: "json", subdirectory: "Fixtures/engine"))
        let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../QSlicerPad/Resources/config").standardized
        return try SettingsCatalog(schemaJSON: String(contentsOf: engine, encoding: .utf8),
                                   layoutJSON: Data(contentsOf: config.appendingPathComponent("config_pages.json")),
                                   frenchJSON: Data(contentsOf: config.appendingPathComponent("config_fr.json")),
                                   useFrench: french)
    }

    func testEveryOptionOfEveryPageHasAnEngineDefinition() throws {
        let c = try catalog()
        var missing: [String] = []
        for tab in c.layout.tabs { for page in tab.pages { for group in page.groups { for line in group.lines {
            for key in line.keys where c.options[key] == nil { missing.append("\(tab.id)/\(key)") }
        } } } }
        XCTAssertTrue(missing.isEmpty, "options de la disposition absentes du schéma du moteur : \(missing)")
        XCTAssertGreaterThan(c.options.count, 300)
    }

    func testTypesAndEnumerations() throws {
        let c = try catalog()
        let known: Set<String> = ["float", "floats", "int", "ints", "string", "strings", "percent", "percents",
                                  "float_or_percent", "floats_or_percents", "point", "points", "point3", "bool", "bools",
                                  "enum", "enums", "unknown"]
        XCTAssertTrue(c.options.values.allSatisfy { known.contains($0.type) })
        let flavor = try XCTUnwrap(c.options["gcode_flavor"])
        XCTAssertEqual(flavor.type, "enum")
        XCTAssertTrue(flavor.enumValues?.contains("klipper") == true)
        XCTAssertEqual(c.options["fill_density"]?.type, "percent")
        XCTAssertEqual(c.options["layer_height"]?.type, "float")
        XCTAssertEqual(c.options["perimeters"]?.type, "int")
        XCTAssertEqual(c.options["support_material"]?.type, "bool")
        XCTAssertEqual(c.options["temperature"]?.isVector, true)
        // chaque énumération a des valeurs pour la fermer
        for o in c.options.values where o.type == "enum" { XCTAssertFalse(o.enumValues?.isEmpty ?? true, o.key) }
    }

    func testFrenchTranslationsAndModes() throws {
        let c = try catalog()
        XCTAssertEqual(c.label(try XCTUnwrap(c.options["layer_height"])), "Hauteur de couche")
        XCTAssertEqual(c.tr("Layers and perimeters"), "Couches et périmètres")
        let english = try catalog(french: false)
        XCTAssertEqual(english.label(try XCTUnwrap(english.options["layer_height"])), "Layer height")
        XCTAssertEqual(c.options["layer_height"]?.mode, .simple)
        XCTAssertEqual(c.options["avoid_crossing_perimeters_max_detour"]?.mode, .expert)
        // le mode filtre : moins d'options en Simple qu'en Expert
        func count(_ mode: ConfigMode) -> Int {
            c.layout.tabs.flatMap(\.pages).reduce(0) { $0 + c.visibleGroups(of: $1, mode: mode).flatMap(\.lines).count }
        }
        XCTAssertLessThan(count(.simple), count(.advanced))
        XCTAssertLessThanOrEqual(count(.advanced), count(.expert))
        XCTAssertGreaterThan(count(.simple), 10)
    }

    func testSearch() throws {
        let c = try catalog()
        let hits = c.search("hauteur de couche", mode: .expert)
        XCTAssertEqual(hits.first?.option.key, "layer_height")
        XCTAssertTrue(c.search("remplissage", mode: .simple).contains { $0.option.key == "fill_density" })
        XCTAssertTrue(c.search("zzzzzz", mode: .expert).isEmpty)
        XCTAssertTrue(c.search("   ", mode: .expert).isEmpty)
        // l'anglais fonctionne aussi
        XCTAssertTrue(try catalog(french: false).search("infill", mode: .simple).contains { $0.option.key == "fill_density" })
    }

    func testEnumLabelsAreTranslated() throws {
        let c = try catalog()
        let seam = try XCTUnwrap(c.options["seam_position"])
        XCTAssertEqual(c.enumLabel(seam, value: "random"), "Aléatoire")
        XCTAssertEqual(c.enumLabel(seam, value: "inconnue"), "inconnue")
    }

    func testOptionValueHelpers() {
        XCTAssertEqual(OptionValue.components("220, 225"), ["220", "225"])
        XCTAssertEqual(OptionValue.first("260,260"), "260")
        XCTAssertEqual(OptionValue.replacingFirst(of: "260,260", with: "255"), "255,255")
        XCTAssertEqual(OptionValue.replacingFirst(of: "260", with: "255"), "255")
        XCTAssertTrue(OptionValue.numberAndPercent("15%")?.1 == true)
        XCTAssertEqual(OptionValue.numberAndPercent("0.45")?.0, 0.45)
        XCTAssertNil(OptionValue.numberAndPercent("abc"))
        XCTAssertEqual(OptionValue.format(15, percent: true), "15%")
        XCTAssertEqual(OptionValue.format(0.45), "0.45")
        XCTAssertTrue(OptionValue.isTrue("1"))
        XCTAssertFalse(OptionValue.isTrue("0"))
    }
}
