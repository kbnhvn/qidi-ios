import XCTest
@testable import QSlicerKit

final class CalibrationTests: XCTestCase {
    func testPressureAdvanceTowerMatchesDesktopRecipe() throws {
        let plan = try Calibration.plan(for: .pressureAdvanceTower(start: 0, end: 0.04, step: 0.002),
                                        base: ["before_layer_gcode": "; ma ligne"], maxPrintHeight: 256)
        XCTAssertEqual(plan.resource, "PressureAdvance/pa_tower.stl")
        XCTAssertEqual(plan.overrides["before_layer_gcode"], "M900 K{int(layer_z / 5) * 0.002 + 0}\n; ma ligne")
        // (0.04 - 0) / 0.002 = 20 pas -> 21 marches de 5 mm
        XCTAssertEqual(plan.targetHeight, 105)
    }

    func testTowerHeightIsCappedByThePrinter() throws {
        let plan = try Calibration.plan(for: .pressureAdvanceTower(start: 0, end: 1, step: 0.001), base: [:], maxPrintHeight: 100)
        XCTAssertEqual(plan.targetHeight, 100)      // floor(100/5) - 1 = 19 pas + 1 marche = 20 × 5 mm
    }

    func testFlowPlans() throws {
        let coarse = try Calibration.plan(for: .flowCoarse, base: ["start_gcode": "G28"], maxPrintHeight: 250)
        XCTAssertEqual(coarse.resource, "FlowRate/flowrate_coarse.3mf")
        XCTAssertEqual(coarse.overrides["start_gcode"], "G28\nM221 S120")
        XCTAssertEqual(coarse.overrides["between_objects_gcode"], "M221 S{120 - 5 * current_object_idx}")
        XCTAssertEqual(coarse.overrides["complete_objects"], "1")

        let fine = try Calibration.plan(for: .flowFine(multiplier: 0.95), base: [:], maxPrintHeight: 250)
        XCTAssertEqual(fine.overrides["start_gcode"], "\nM221 S99")
        XCTAssertEqual(fine.overrides["between_objects_gcode"], "M221 S{ 99 - current_object_idx}")
    }

    func testInvalidInputsAreRejected() {
        XCTAssertThrowsError(try Calibration.plan(for: .pressureAdvanceTower(start: 0.04, end: 0, step: 0.002), base: [:], maxPrintHeight: 250))
        XCTAssertThrowsError(try Calibration.plan(for: .pressureAdvanceTower(start: 0, end: 0.04, step: 0), base: [:], maxPrintHeight: 250))
        XCTAssertThrowsError(try Calibration.plan(for: .flowFine(multiplier: 3), base: [:], maxPrintHeight: 250))
    }

    func testNumberFormatting() {
        XCTAssertEqual(Calibration.format(0.04), "0.04")
        XCTAssertEqual(Calibration.format(0.002), "0.002")
        XCTAssertEqual(Calibration.format(0), "0")
        XCTAssertEqual(Calibration.format(1), "1")
    }
}
