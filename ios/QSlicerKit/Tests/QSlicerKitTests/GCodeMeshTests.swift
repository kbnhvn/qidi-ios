import XCTest
@testable import QSlicerKit

final class GCodeMeshTests: XCTestCase {
    private func move(_ x: Float, _ y: Float, _ z: Float, layer: UInt32, type: GCodeMoveType = .extrude,
                      role: GCodeRole = .perimeter, feed: Float = 50, width: Float = 0.45, height: Float = 0.2) -> GCodeMove {
        GCodeMove(x: x, y: y, z: z, feedrate: feed, width: width, height: height, fanSpeed: 100, temperature: 220,
                  time: 0.1, eDelta: 0.05, layer: layer, type: type.rawValue, role: role.rawValue)
    }

    /// Deux couches : un carré de 10 mm (4 segments) chacune, plus un déplacement.
    private func squareMoves() -> [GCodeMove] {
        var m: [GCodeMove] = []
        for layer in 0..<2 {
            let z = Float(layer + 1) * 0.2
            m.append(move(0, 0, z, layer: UInt32(layer), type: .travel))
            m.append(move(10, 0, z, layer: UInt32(layer)))
            m.append(move(10, 10, z, layer: UInt32(layer), role: .externalPerimeter))
            m.append(move(0, 10, z, layer: UInt32(layer), role: .internalInfill))
            m.append(move(0, 0, z, layer: UInt32(layer), role: .topSolidInfill, feed: 100))
        }
        return m
    }

    func testRibbonsPerLayerWithFullDetail() {
        let mesh = GCodeMeshBuilder().build(moves: squareMoves())
        XCTAssertEqual(mesh.layers.count, 2)
        XCTAssertTrue(mesh.fullDetail)
        XCTAssertEqual(mesh.segmentCount, 8)
        // 4 segments × (haut 4 + 2 flancs 2 sommets) = 8 sommets par segment
        XCTAssertEqual(mesh.layers[0].positions.count / 3, 4 * 8)
        XCTAssertEqual(mesh.layers[0].indices.count, 4 * 18)
        XCTAssertEqual(mesh.layers[0].colors.count / 4, mesh.layers[0].positions.count / 3)
        XCTAssertEqual(mesh.layers[1].z, 0.4, accuracy: 1e-6)
        XCTAssertEqual(mesh.layers[0].travel.count, 0, "pas de départ avant le premier mouvement")
        XCTAssertEqual(mesh.boundsMax.x, 10, accuracy: 1e-6)
    }

    func testIndicesStayInRange() {
        let mesh = GCodeMeshBuilder().build(moves: squareMoves())
        for layer in mesh.layers {
            let count = UInt32(layer.positions.count / 3)
            XCTAssertTrue(layer.indices.allSatisfy { $0 < count })
        }
    }

    func testFeatureColorsFollowDesktopPalette() {
        let mesh = GCodeMeshBuilder().build(moves: squareMoves())
        let c = mesh.layers[0].colors
        // premier segment : périmètre jaune, sommets du dessus (255, 230, 77)
        XCTAssertEqual(Array(c[0..<4]), [255, 230, 77, 255])
        XCTAssertNil(mesh.valueRange)
    }

    func testScalarModeUsesRangeAndGradient() {
        var builder = GCodeMeshBuilder()
        builder.mode = .speed
        let mesh = builder.build(moves: squareMoves())
        XCTAssertEqual(mesh.valueRange?.min, 50)
        XCTAssertEqual(mesh.valueRange?.max, 100)
        let slowFirst = mesh.layers[0].colors[0..<3]
        let fastLast = mesh.layers[0].colors[(3 * 8 * 4)..<(3 * 8 * 4 + 3)]   // 4e segment (le plus rapide)
        XCTAssertNotEqual(Array(slowFirst), Array(fastLast))
        let lowColor = gcodeRangeColor(0), highColor = gcodeRangeColor(1)
        XCTAssertNotEqual(lowColor.0, highColor.0)
        XCTAssertEqual(gcodeRangeColor(-3).0, lowColor.0, "t borné à [0,1]")
    }

    func testHiddenRolesAndTravel() {
        var builder = GCodeMeshBuilder()
        builder.hiddenRoles = [GCodeRole.externalPerimeter.rawValue]
        XCTAssertEqual(builder.build(moves: squareMoves()).segmentCount, 6)
        builder.hiddenRoles = []
        builder.includeTravel = false
        XCTAssertTrue(builder.build(moves: squareMoves()).layers.allSatisfy { $0.travel.isEmpty })
        // un déplacement entre deux extrusions est enregistré
        let moves = [move(0, 0, 0.2, layer: 0, type: .travel), move(5, 5, 0.2, layer: 0, type: .travel)]
        XCTAssertEqual(GCodeMeshBuilder().build(moves: moves).layers[0].travel.count, 6)
    }

    func testBudgetsReduceDetailThenSimplify() {
        var builder = GCodeMeshBuilder()
        builder.fullDetailBudget = 4
        var mesh = builder.build(moves: squareMoves())
        XCTAssertFalse(mesh.fullDetail)
        XCTAssertEqual(mesh.layers[0].indices.count, 4 * 6)
        builder.simplifyBudget = 4
        mesh = builder.build(moves: squareMoves())
        XCTAssertTrue(mesh.simplified)
        XCTAssertEqual(mesh.segmentCount, 2 * 3, "le remplissage interne est omis, le plein supérieur est conservé")
    }

    func testEmptyInput() {
        let mesh = GCodeMeshBuilder().build(moves: [])
        XCTAssertTrue(mesh.layers.isEmpty)
        XCTAssertEqual(mesh.boundsMin, .zero)
    }
}
