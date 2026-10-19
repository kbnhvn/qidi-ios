import XCTest
@testable import QSlicerKit

/// QIDI Box (emplacements, commandes Klipper) et couleurs par outil de l'aperçu.
final class QIDIBoxTests: XCTestCase {
    func testTrayNames() {
        XCTAssertEqual(QIDIBox.trayName(0), "1A")
        XCTAssertEqual(QIDIBox.trayName(3), "1D")
        XCTAssertEqual(QIDIBox.trayName(4), "2A")
        XCTAssertEqual(QIDIBox.trayName(15), "4D")
        XCTAssertEqual(QIDIBox.trayName(16), "?")
        XCTAssertEqual(QIDIBox.trayName(-1), "?")
        XCTAssertEqual(QIDIBox.allTrays.count, 16)
        XCTAssertEqual(Set(QIDIBox.allTrays.map(\.name)).count, 16, "noms uniques")
        XCTAssertEqual(QIDIBox.defaultSlots(count: 3), [0, 1, 2])
        XCTAssertEqual(QIDIBox.defaultSlots(count: 0), [])
    }

    func testActivationCommandsMatchDesktop() {
        let commands = QIDIBox.activationCommands(slots: [4, 1, 15], enabled: true)
        XCTAssertEqual(commands, [
            "SAVE_VARIABLE VARIABLE=enable_box VALUE=1",
            #"SAVE_VARIABLE VARIABLE=value_t0 VALUE=\"'slot4'\""#,
            #"SAVE_VARIABLE VARIABLE=value_t1 VALUE=\"'slot1'\""#,
            #"SAVE_VARIABLE VARIABLE=value_t2 VALUE=\"'slot15'\""#,
        ])
        XCTAssertEqual(QIDIBox.activationCommands(slots: [4], enabled: false), ["SAVE_VARIABLE VARIABLE=enable_box VALUE=0"])
        // un emplacement hors plage est ignoré (jamais d'ordre invalide envoyé à l'imprimante)
        XCTAssertEqual(QIDIBox.activationCommands(slots: [99, 2], enabled: true).count, 2)
    }

    func testParseSaveVariables() throws {
        let json = #"{"result":{"status":{"save_variables":{"variables":{"enable_box":1,"value_t0":"'slot3'","value_t1":"'slot12'","other":5}}}}}"#
        let v = try XCTUnwrap(QIDIBox.parseVariables(Data(json.utf8)))
        XCTAssertTrue(v.enabled)
        XCTAssertEqual(v.slots[0], 3)
        XCTAssertEqual(v.slots[1], 12)
        XCTAssertNil(v.slots[2])
        XCTAssertEqual(v.slots.count, 16)
        let off = try XCTUnwrap(QIDIBox.parseVariables(Data(#"{"result":{"status":{"save_variables":{"variables":{}}}}}"#.utf8)))
        XCTAssertFalse(off.enabled)
        XCTAssertNil(QIDIBox.parseVariables(Data(#"{"result":{"status":{}}}"#.utf8)))
        XCTAssertNil(QIDIBox.parseVariables(Data("pas json".utf8)))
    }

    func testToolColoursInThePreview() {
        XCTAssertEqual(GCodeMeshBuilder.parseColors("#FF8000;#00ff00").map { [$0.0, $0.1, $0.2] }, [[255, 128, 0], [0, 255, 0]])
        XCTAssertEqual(GCodeMeshBuilder.parseColors("n'importe quoi").map { $0.0 }, [160], "illisible : gris")
        XCTAssertEqual(GCodeMeshBuilder.parseColors("\"#112233\"").first.map { [$0.0, $0.1, $0.2] }, [17, 34, 51])

        func move(_ x: Float, tool: UInt8, layer: UInt32 = 0, type: GCodeMoveType = .extrude) -> GCodeMove {
            GCodeMove(x: x, y: 0, z: 0.2, feedrate: 50, width: 0.45, height: 0.2, fanSpeed: 0, temperature: 200, time: 0.1,
                      eDelta: 0.1, layer: layer, type: type.rawValue, role: GCodeRole.perimeter.rawValue, extruder: tool)
        }
        var builder = GCodeMeshBuilder()
        builder.mode = .tool
        builder.toolColors = [(255, 0, 0), (0, 0, 255)]
        let mesh = builder.build(moves: [move(0, tool: 0, type: .travel), move(5, tool: 0), move(10, tool: 1)])
        XCTAssertNil(mesh.valueRange, "mode catégoriel : pas de dégradé")
        let colors = mesh.layers[0].colors
        // un ruban = 4 sommets de dessus + 4 de flancs ; face supérieure : couleur pleine
        XCTAssertEqual(Array(colors[0..<3]), [255, 0, 0], "outil 0 en rouge")
        XCTAssertEqual(Array(colors[(colors.count - 32)..<(colors.count - 29)]), [0, 0, 255], "outil 1 en bleu")
        // sans couleur de configuration : palette de secours, jamais d'accès hors tableau
        builder.toolColors = []
        XCTAssertEqual(builder.toolColor(9).0, GCodeMeshBuilder.fallbackToolColors[9 % GCodeMeshBuilder.fallbackToolColors.count].0)
        XCTAssertTrue(GCodeColorMode.tool.isCategorical && GCodeColorMode.featureType.isCategorical && !GCodeColorMode.speed.isCategorical)
    }
}
