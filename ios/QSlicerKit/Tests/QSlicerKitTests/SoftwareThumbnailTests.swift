import XCTest
@testable import QSlicerKit

final class SoftwareThumbnailTests: XCTestCase {
    /// Cube de 20 mm posé sur le plateau (12 triangles, sommets en coordonnées locales).
    private func cube() -> [Float] {
        let v: [[Float]] = [[-10, -10, -10], [10, -10, -10], [10, 10, -10], [-10, 10, -10],
                            [-10, -10, 10], [10, -10, 10], [10, 10, 10], [-10, 10, 10]]
        let faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                     [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        return faces.flatMap { $0.flatMap { v[$0] } }
    }

    private let identityAt10: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 10, 10, 1]

    private func pixel(_ rgba: [UInt8], _ x: Int, _ y: Int, width: Int) -> [UInt8] {
        let o = (y * width + x) * 4
        return Array(rgba[o..<o + 4])
    }

    func testCubeIsDrawnInTheMiddleOnABackground() {
        let item = SoftwareThumbnail.Item(triangles: cube(), matrices: [identityAt10])
        let rgba = SoftwareThumbnail.render(items: [item], boundsMin: Vec3(0, 0, 0), boundsMax: Vec3(20, 20, 20), width: 96, height: 96)
        XCTAssertEqual(rgba.count, 96 * 96 * 4)
        let bg = SoftwareThumbnail.background
        XCTAssertEqual(pixel(rgba, 1, 1, width: 96), [bg.0, bg.1, bg.2, 255], "coin : fond")
        let centre = pixel(rgba, 48, 48, width: 96)
        XCTAssertNotEqual(Array(centre[0..<3]), [bg.0, bg.1, bg.2], "centre : le cube")
        XCTAssertEqual(centre[3], 255)
        XCTAssertGreaterThan(centre[0], centre[2], "teinte orangée (rouge > bleu)")
        // une part raisonnable de l'image est couverte, sans la remplir
        var covered = 0
        for y in 0..<96 { for x in 0..<96 where pixel(rgba, x, y, width: 96)[0] != bg.0 { covered += 1 } }
        XCTAssertGreaterThan(covered, 96 * 96 / 10)
        XCTAssertLessThan(covered, 96 * 96 * 8 / 10)
    }

    func testDeterministicAndNonSquare() {
        let item = SoftwareThumbnail.Item(triangles: cube(), matrices: [identityAt10, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 40, 10, 10, 1]])
        let a = SoftwareThumbnail.render(items: [item], boundsMin: Vec3(0, 0, 0), boundsMax: Vec3(50, 20, 20), width: 160, height: 90)
        let b = SoftwareThumbnail.render(items: [item], boundsMin: Vec3(0, 0, 0), boundsMax: Vec3(50, 20, 20), width: 160, height: 90)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 160 * 90 * 4)
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertEqual(SoftwareThumbnail.render(items: [], boundsMin: .zero, boundsMax: .zero, width: 8, height: 8).count, 8 * 8 * 4)
        XCTAssertTrue(SoftwareThumbnail.render(items: [], boundsMin: .zero, boundsMax: .zero, width: 0, height: 8).isEmpty)
        // triangles dégénérés et matrice invalide : pas de plantage
        let flat = SoftwareThumbnail.Item(triangles: [0, 0, 0, 0, 0, 0, 0, 0, 0], matrices: [identityAt10, [1, 2, 3]])
        XCTAssertEqual(SoftwareThumbnail.render(items: [flat], boundsMin: .zero, boundsMax: Vec3(1, 1, 1), width: 16, height: 16).count, 16 * 16 * 4)
    }

    func testNearerFaceWinsTheDepthTest() {
        // deux grands triangles superposés de profondeurs différentes, vus depuis la caméra iso
        let near: [Float] = [-30, -30, 30, 30, -30, 30, 0, 30, 30]
        let far: [Float] = [-30, -30, -30, 30, -30, -30, 0, 30, -30]
        let m: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let both = SoftwareThumbnail.render(items: [.init(triangles: far + near, matrices: [m])], boundsMin: Vec3(-30, -30, -30), boundsMax: Vec3(30, 30, 30), width: 64, height: 64)
        let swapped = SoftwareThumbnail.render(items: [.init(triangles: near + far, matrices: [m])], boundsMin: Vec3(-30, -30, -30), boundsMax: Vec3(30, 30, 30), width: 64, height: 64)
        XCTAssertEqual(both, swapped, "l'ordre des triangles ne change pas l'image")
    }
}
