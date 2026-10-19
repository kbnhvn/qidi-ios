import XCTest
@testable import QSlicerKit

/// Coupe, réglages par objet, modificateurs, plages de hauteurs, sélection multiple :
/// décodage de sorties réelles du moteur et logique pure associée.
final class ObjectToolsTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/engine"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func cube(at x: Double, id: UInt64 = 1) -> SceneObject {
        let inst = SceneInstance(offset: [x + 10, 10, 10], rotationDeg: [0, 0, 0], scale: [1, 1, 1],
                                 min: [x, 0, 0], max: [x + 20, 20, 20], outside: false,
                                 matrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x + 10, 10, 10, 1])
        return SceneObject(id: id, name: "cube", triangles: 12, localMin: [-10, -10, -10], localMax: [10, 10, 10], instances: [inst])
    }

    // MARK: Décodage

    func testObjectSettingsDecodedFromEngine() throws {
        let info = try SceneJSON.decode(SceneInfo.self, from: fixture("scene_info_objects"))
        let object = try XCTUnwrap(info.objects.first)
        XCTAssertEqual(object.volumes.count, 2)
        XCTAssertEqual(object.modifiers.count, 1)
        let modifier = try XCTUnwrap(object.modifiers.first)
        XCTAssertEqual(modifier.kind, "modifier")
        XCTAssertEqual(modifier.name, "box")
        XCTAssertEqual(modifier.size, [12, 12, 12])
        XCTAssertEqual(modifier.config["fill_density"], "100%")
        XCTAssertEqual(object.layerRanges.count, 1)
        XCTAssertEqual(object.layerRanges[0].min, 5)
        XCTAssertEqual(object.layerRanges[0].max, 10)
        XCTAssertEqual(object.layerRanges[0].config["layer_height"], "0.1")
        XCTAssertTrue(object.hasCustomSettings)
        XCTAssertEqual(object.volumes.first?.kind, "part")
        XCTAssertFalse(object.volumes[0].isModifier)
    }

    func testOldSceneInfoStillDecodes() throws {
        let info = try SceneJSON.decode(SceneInfo.self, from: fixture("scene_info"))
        let object = try XCTUnwrap(info.objects.first)
        XCTAssertTrue(object.config.isEmpty)
        XCTAssertTrue(object.volumes.isEmpty)
        XCTAssertTrue(object.layerRanges.isEmpty)
        XCTAssertFalse(object.hasCustomSettings)
    }

    func testResultTypes() throws {
        XCTAssertEqual(try SceneJSON.decode(SceneCutResult.self, from: #"{"objects":[5,6]}"#).objects, [5, 6])
        let simplified = try SceneJSON.decode(SceneSimplifyResult.self, from: #"{"before":2208,"after":552}"#)
        XCTAssertEqual(simplified.before, 2208)
        XCTAssertEqual(simplified.after, 552)
    }

    func testSchemaMarksPerObjectOptions() throws {
        let list = try JSONDecoder().decode([ConfigOptionProbe].self, from: Data(fixture("schema").utf8))
        let byKey = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
        XCTAssertEqual(byKey["fill_density"]?.per_object, true)
        XCTAssertEqual(byKey["bed_temperature"]?.per_object, false)
        // toutes les options proposées d'emblée doivent être acceptées par le moteur par objet
        for key in ObjectSettings.quickKeys {
            XCTAssertEqual(byKey[key]?.per_object, true, "\(key) n'est pas un réglage par objet")
        }
    }

    private struct ConfigOptionProbe: Decodable {
        let key: String
        let per_object: Bool?
    }

    // MARK: Plan de coupe

    func testCutPlaneRangeAndDefault() throws {
        let object = cube(at: 0)
        let plane = try XCTUnwrap(CutPlane.centered(on: object))
        XCTAssertEqual(plane.axis, .z)
        XCTAssertEqual(plane.position, 10, accuracy: 1e-9)
        let inst = object.instances[0]
        XCTAssertEqual(CutPlane.range(of: inst, axis: .z), 0.1...19.9)
        XCTAssertTrue(plane.isValid(for: inst))
        XCTAssertFalse(CutPlane(objectID: 1, axis: .z, position: 20).isValid(for: inst), "le plan doit traverser l'objet")
        XCTAssertFalse(CutPlane(objectID: 1, axis: .z, position: 0).isValid(for: inst))
        let halves = plane.halves(of: inst)
        XCTAssertEqual(halves.lower, 10, accuracy: 1e-9)
        XCTAssertEqual(halves.upper, 10, accuracy: 1e-9)
    }

    func testCutPlanePointAndNormal() {
        let inst = cube(at: 30).instances[0]
        let z = CutPlane(objectID: 1, axis: .z, position: 7)
        XCTAssertEqual(z.point(in: inst), [40, 10, 7])
        XCTAssertEqual(z.axis.normal, [0, 0, 1])
        let x = CutPlane(objectID: 1, axis: .x, position: 35)
        XCTAssertEqual(x.point(in: inst), [35, 10, 10])
        XCTAssertEqual(x.axis.normal, [1, 0, 0])
        XCTAssertEqual(CutPlane(objectID: 1, axis: .y, position: 3).axis.normal, [0, 1, 0])
        XCTAssertEqual(CutPlane.Keep.both.rawValue, 3)
        XCTAssertEqual(CutPlane.Keep.upper.rawValue | CutPlane.Keep.lower.rawValue, CutPlane.Keep.both.rawValue)
    }

    func testTinyObjectCannotBeCut() {
        var object = cube(at: 0)
        object.instances[0].max = [20, 20, 0.15]
        XCTAssertNil(CutPlane.centered(on: object), "0,15 mm d'épaisseur : pas de plan utile")
    }

    // MARK: Modificateurs et plages

    func testDefaultModifierIsInsideObject() {
        let inst = cube(at: 0).instances[0]
        let m = ObjectSettings.defaultModifier(for: inst)
        XCTAssertEqual(m.center, [10, 10, 10])
        XCTAssertEqual(m.size, [8, 8, 8])
    }

    func testWorldCenterAppliesInstanceMatrix() {
        // translation (10, 20, 30) + rotation de 90° autour de Z : (1,0,0) -> (0,1,0)
        let matrix: [Double] = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1]
        let w = ObjectSettings.worldCenter(local: [1, 0, 0], matrix: matrix)
        XCTAssertEqual(w[0], 10, accuracy: 1e-9)
        XCTAssertEqual(w[1], 21, accuracy: 1e-9)
        XCTAssertEqual(w[2], 30, accuracy: 1e-9)
        XCTAssertEqual(ObjectSettings.worldCenter(local: [1, 2, 3], matrix: []), [1, 2, 3])
    }

    func testDefaultLayerRangeFollowsExistingOnes() throws {
        var object = cube(at: 0)
        var range = try XCTUnwrap(ObjectSettings.defaultLayerRange(for: object))
        XCTAssertEqual(range.min, 0)
        XCTAssertEqual(range.max, 5)
        object.layerRanges = [SceneLayerRange(min: 0, max: 5, config: [:])]
        range = try XCTUnwrap(ObjectSettings.defaultLayerRange(for: object))
        XCTAssertEqual(range.min, 5)
        XCTAssertEqual(range.max, 10)
        object.layerRanges = [SceneLayerRange(min: 0, max: 19.9, config: [:])]
        XCTAssertNil(ObjectSettings.defaultLayerRange(for: object), "plus de place")
    }

    // MARK: Sélection multiple

    func testSelectionGroupBoundsAndClamp() throws {
        let a = cube(at: 0, id: 1), b = cube(at: 100, id: 2)
        let bounds = try XCTUnwrap(SelectionGroup.bounds(of: [a, b]))
        XCTAssertEqual(bounds.min, Vec3(0, 0, 0))
        XCTAssertEqual(bounds.max, Vec3(120, 20, 20))
        XCTAssertNil(SelectionGroup.bounds(of: []))

        let bed = try SceneJSON.decode(SceneInfo.self, from: fixture("scene_info")).bed   // 270 × 270
        // le groupe entier va buter à droite (120 + 200 > 270) : le décalage est ramené à 150
        let shift = SelectionGroup.clampedShift(of: [a, b], dx: 200, dy: 0, bed: bed)
        XCTAssertEqual(shift.x, 150, accuracy: 1e-9)
        XCTAssertEqual(shift.y, 0, accuracy: 1e-9)
        let left = SelectionGroup.clampedShift(of: [a, b], dx: -30, dy: -30, bed: bed)
        XCTAssertEqual(left.x, 0, accuracy: 1e-9)
        XCTAssertEqual(left.y, 0, accuracy: 1e-9)
    }
}

/// Préréglages utilisateur : héritage des presets système, ancien format, noms.
final class UserPresetTests: XCTestCase {
    func testParentLabel() {
        var preset = UserPreset(name: "Mon essai", printer: "Q2 0.4 nozzle", print: "0.20mm Standard @Q2 0.4 nozzle",
                                filament: "QIDI PLA @Q2 0.4 nozzle", overrides: SliceOverrides())
        XCTAssertTrue(preset.hasParents)
        XCTAssertEqual(preset.parentLabel, "0.20mm Standard")
        preset.print = ""
        XCTAssertEqual(preset.parentLabel, "Q2 0.4 nozzle")
        XCTAssertNil(UserPreset(name: "x", overrides: SliceOverrides()).parentLabel)
    }

    func testRoundTripAndLegacyFormat() throws {
        var overrides = SliceOverrides()
        overrides.set("perimeters", "4", base: ["perimeters": "2"])
        let preset = UserPreset(name: "Solide", printer: "P", print: "R", filament: "F", overrides: overrides)
        let data = try XCTUnwrap(UserPresetStore.encode(["Solide": preset]))
        XCTAssertEqual(UserPresetStore.decode(data), ["Solide": preset])

        // ancien format : { nom: SliceOverrides } — conservé, sans parents
        let legacy = try JSONEncoder().encode(["Ancien": overrides])
        let migrated = UserPresetStore.decode(legacy)
        XCTAssertEqual(migrated["Ancien"]?.overrides, overrides)
        XCTAssertEqual(migrated["Ancien"]?.hasParents, false)
        XCTAssertTrue(UserPresetStore.decode(Data("pas du json".utf8)).isEmpty)
    }

    func testUniqueName() {
        XCTAssertEqual(UserPresetStore.uniqueName("Essai", existing: []), "Essai")
        XCTAssertEqual(UserPresetStore.uniqueName("Essai", existing: ["Essai"]), "Essai 2")
        XCTAssertEqual(UserPresetStore.uniqueName("  Essai  ", existing: ["Essai", "Essai 2"]), "Essai 3")
        XCTAssertEqual(UserPresetStore.uniqueName("   ", existing: []), "")
    }
}
