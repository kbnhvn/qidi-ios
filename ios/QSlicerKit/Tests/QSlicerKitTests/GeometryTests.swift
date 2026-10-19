import XCTest
@testable import QSlicerKit

final class PickingTests: XCTestCase {
    func testRayPlaneAndBox() {
        let ray = Ray(origin: Vec3(10, 20, 100), direction: simd_normalize(Vec3(0, 0, -1)))
        XCTAssertEqual(Picking.intersect(ray, planeZ: 0)?.z ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(Picking.intersect(ray, planeZ: 0)?.x ?? -1, 10, accuracy: 1e-9)
        XCTAssertNil(Picking.intersect(ray, planeZ: 500), "plan derrière l'origine")
        let hit = Picking.intersect(ray, boxMin: Vec3(0, 0, 0), boxMax: Vec3(20, 40, 30))
        XCTAssertEqual(hit ?? -1, 70, accuracy: 1e-9)
        XCTAssertNil(Picking.intersect(ray, boxMin: Vec3(50, 50, 0), boxMax: Vec3(60, 60, 30)))
    }

    func testTrianglePickReturnsNearestFaceThroughInstanceMatrix() {
        // Deux triangles horizontaux empilés (z = 0 et z = 10), translatés de +5 en X.
        let tris: [Float] = [0, 0, 0,  10, 0, 0,  0, 10, 0,
                             0, 0, 10, 10, 0, 10, 0, 10, 10]
        var m = [Double](repeating: 0, count: 16)
        m[0] = 1; m[5] = 1; m[10] = 1; m[15] = 1; m[12] = 5   // translation X
        let ray = Ray(origin: Vec3(7, 2, 50), direction: Vec3(0, 0, -1))
        let hit = Picking.pickTriangle(ray, localTriangles: tris, matrix: m)
        XCTAssertEqual(hit?.index, 1)                   // le triangle du haut est touché d'abord
        XCTAssertEqual(hit?.distance ?? 0, 40, accuracy: 1e-9)
        XCTAssertNil(Picking.pickTriangle(Ray(origin: Vec3(30, 2, 50), direction: Vec3(0, 0, -1)), localTriangles: tris, matrix: m))
    }

    func testSnapping() {
        XCTAssertEqual(Snapping.snap(12.4, step: 5), 10)
        XCTAssertEqual(Snapping.snap(12.6, step: 5), 15)
        XCTAssertEqual(Snapping.snap(12.6, step: 0), 12.6)
        XCTAssertEqual(Snapping.snapAngle(88), 90)
        XCTAssertEqual(Snapping.snapAngle(82), 82)
    }

    func testBedBoundsAndClamp() throws {
        let bed = try SceneJSON.decode(SceneBed.self, from: #"{"shape":[[0,0],[270,0],[270,270],[0,270]],"max_height":256}"#)
        XCTAssertFalse(BedBounds.isOutside(min: Vec3(10, 10, 0), max: Vec3(30, 30, 20), bed: bed))
        XCTAssertTrue(BedBounds.isOutside(min: Vec3(-5, 10, 0), max: Vec3(15, 30, 20), bed: bed))
        XCTAssertTrue(BedBounds.isOutside(min: Vec3(10, 10, 0), max: Vec3(30, 30, 300), bed: bed))
        let shift = BedBounds.clampingShift(min: Vec3(-5, 260, 0), max: Vec3(15, 280, 20), bed: bed)
        XCTAssertEqual(shift.x, 5, accuracy: 1e-9)
        XCTAssertEqual(shift.y, -10, accuracy: 1e-9)
        XCTAssertEqual(BedBounds.clampingShift(min: Vec3(10, 10, 0), max: Vec3(20, 20, 5), bed: bed), SIMD2(0, 0))
    }
}

final class CameraTests: XCTestCase {
    func testOrbitClampsElevationAndKeepsDistance() {
        var cam = OrbitCamera(target: Vec3(100, 100, 0), distance: 300, azimuth: 0, elevation: 30)
        cam.orbit(deltaX: 50, deltaY: 1000)
        XCTAssertEqual(cam.elevation, 90)
        cam.orbit(deltaX: 0, deltaY: -10000)
        XCTAssertEqual(cam.elevation, OrbitCamera.minElevation)
        XCTAssertEqual(simd_length(cam.position - cam.target), 300, accuracy: 1e-6)
    }

    func testZoomIsClampedAndMonotonic() {
        var cam = OrbitCamera(distance: 300)
        cam.zoom(scale: 2)
        XCTAssertEqual(cam.distance, 150, accuracy: 1e-9)
        cam.zoom(scale: 1000)
        XCTAssertEqual(cam.distance, 30)
        cam.zoom(scale: 0.0001)
        XCTAssertEqual(cam.distance, 3000)
    }

    func testPanMovesTargetInScreenPlane() {
        var cam = OrbitCamera(target: .zero, distance: 300, azimuth: 0, elevation: 90)
        let before = cam.target
        cam.pan(deltaX: 100, deltaY: 0, viewHeight: 800)
        let moved = cam.target - before
        XCTAssertLessThan(moved.x, 0, "glisser à droite fait avancer la scène vers la droite (cible à gauche)")
        XCTAssertEqual(moved.z, 0, accuracy: 1e-9)
    }

    func testCenterRayHitsTargetAndTopViewMapsScreenToBed() {
        var cam = OrbitCamera(target: Vec3(135, 135, 0), distance: 500, azimuth: 0, elevation: 90)
        let size = SIMD2(800.0, 600.0)
        let center = cam.ray(at: SIMD2(400, 300), viewSize: size)
        let hit = Picking.intersect(center, planeZ: 0)!
        XCTAssertEqual(hit.x, 135, accuracy: 1e-6)
        XCTAssertEqual(hit.y, 135, accuracy: 1e-6)
        // Vue de dessus : un point à droite de l'écran est à droite (X+), en haut = Y+.
        let right = Picking.intersect(cam.ray(at: SIMD2(600, 300), viewSize: size), planeZ: 0)!
        let top = Picking.intersect(cam.ray(at: SIMD2(400, 100), viewSize: size), planeZ: 0)!
        XCTAssertGreaterThan(right.x, 135)
        XCTAssertGreaterThan(top.y, 135)
        cam.azimuth = 90
        let rotated = Picking.intersect(cam.ray(at: SIMD2(600, 300), viewSize: size), planeZ: 0)!
        XCTAssertNotEqual(rotated.x, right.x)
    }

    func testFrameContainsBox() {
        var cam = OrbitCamera()
        cam.frame(min: Vec3(0, 0, 0), max: Vec3(270, 270, 256), aspect: 1.5)
        XCTAssertEqual(cam.target.x, 135, accuracy: 1e-9)
        XCTAssertGreaterThan(cam.distance, 270)
    }
}

final class FilamentIndexTests: XCTestCase {
    private let names = [
        "QIDI PLA Rapido @Q2 0.4 nozzle", "QIDI PETG-Tough @Q2 0.4 nozzle", "QIDI ABS Odorless @Q2 0.4 nozzle",
        "Generic PETG @Q2 0.4 nozzle", "QIDI PAHT-CF @Q2 0.4 nozzle", "QIDI UltraPA-CF25 @Q2 0.4 nozzle",
        "QIDI PC/ABS-FR @Q2 0.4 nozzle", "QIDI PET-CF @Q2 0.4 nozzle", "QIDI Support For PET/PA @Q2 0.4 nozzle",
        "QIDI TPU 95A-HF @Q2 0.4 nozzle", "QIDI WOOD Rapido @Q2 0.4 nozzle", "QIDI ASA-Aero @Q2 0.4 nozzle",
    ]

    func testMaterialDetection() {
        let byName = Dictionary(uniqueKeysWithValues: FilamentIndex.entries(names).map { ($0.display, $0.material) })
        XCTAssertEqual(byName["QIDI PLA Rapido"], "PLA")
        XCTAssertEqual(byName["QIDI PETG-Tough"], "PETG")
        XCTAssertEqual(byName["Generic PETG"], "PETG")
        XCTAssertEqual(byName["QIDI ABS Odorless"], "ABS")
        XCTAssertEqual(byName["QIDI PAHT-CF"], "PA")
        XCTAssertEqual(byName["QIDI UltraPA-CF25"], "PA")
        XCTAssertEqual(byName["QIDI PC/ABS-FR"], "PC")
        XCTAssertEqual(byName["QIDI PET-CF"], "PET")
        XCTAssertEqual(byName["QIDI Support For PET/PA"], "Support")
        XCTAssertEqual(byName["QIDI TPU 95A-HF"], "TPU")
        XCTAssertEqual(byName["QIDI WOOD Rapido"], "PLA")
        XCTAssertEqual(byName["QIDI ASA-Aero"], "ASA")
    }

    func testSearchAndGrouping() {
        let entries = FilamentIndex.entries(names)
        XCTAssertEqual(FilamentIndex.search(entries, query: "petg").count, 2)
        XCTAssertEqual(FilamentIndex.search(entries, query: "qidi abs").count, 2)   // ABS Odorless + PC/ABS-FR
        XCTAssertEqual(FilamentIndex.search(entries, query: "  ").count, entries.count)
        XCTAssertTrue(FilamentIndex.search(entries, query: "zzz").isEmpty)
        let groups = FilamentIndex.grouped(entries)
        XCTAssertEqual(groups.first?.material, "PLA")
        XCTAssertEqual(groups.map(\.material).prefix(3), ["PLA", "PETG", "ABS"])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.items.count }, entries.count)
    }

    func testRealBundleHasNoUncategorizedFilament() throws {
        let path = ProcessInfo.processInfo.environment["QSID_PROFILES_INI"] ?? "/home/user/qiditech/qidislicer/resources/profiles/QIDITechnology.ini"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("bundle absent") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let names = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("[filament:"), line.hasSuffix("]"), !line.contains("*") else { return nil }
            return String(line.dropFirst(10).dropLast())
        }
        let entries = FilamentIndex.entries(names)
        XCTAssertGreaterThan(Set(entries.map(\.display)).count, 40)
        let other = Set(entries.filter { $0.material == "Autre" }.map(\.display))
        XCTAssertTrue(other.isEmpty, "non classés : \(other)")
    }
}
