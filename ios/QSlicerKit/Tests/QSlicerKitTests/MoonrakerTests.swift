import XCTest
@testable import QSlicerKit

final class MoonrakerTests: XCTestCase {
    func testStatusParsing() {
        let json = #"""
        {"result":{"status":{
          "print_stats":{"state":"printing","filename":"cube.gcode","message":""},
          "display_status":{"progress":0.42},
          "extruder":{"temperature":219.7,"target":220.0},
          "heater_bed":{"temperature":59.9,"target":60.0}}}}
        """#
        let s = PrinterStatus.parse(Data(json.utf8))
        XCTAssertEqual(s.state, "printing")
        XCTAssertEqual(s.filename, "cube.gcode")
        XCTAssertEqual(s.progress, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.nozzleTarget, 220)
        XCTAssertEqual(s.bed ?? 0, 59.9, accuracy: 1e-9)
        XCTAssertEqual(s.stateLabel, "Impression en cours")
        XCTAssertEqual(PrinterStatus.parse(Data("{}".utf8)).state, "inconnu")
        XCTAssertEqual(PrinterStatus.parse(Data("pas du json".utf8)), PrinterStatus())
    }

    func testBaseURL() {
        var c = MoonrakerConfig()
        XCTAssertFalse(c.isConfigured)
        c.host = "192.168.1.42"
        XCTAssertEqual(c.baseURL?.absoluteString, "http://192.168.1.42:7125")
        c.host = "https://qidi.local:8443"
        XCTAssertEqual(c.baseURL?.absoluteString, "https://qidi.local:8443")
    }

    func testMultipartBodyIsStreamedWithFieldsAndFooter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.gcode")
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })       // > 2 blocs de 1 Mo
        try payload.write(to: source)
        let out = dir.appendingPathComponent("body")
        try MultipartBody.write(file: source, filename: "a \"b\".gcode", fields: ["root": "gcodes"], boundary: "BND", to: out)

        let body = try Data(contentsOf: out)
        let text = String(decoding: body.prefix(400), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--BND\r\nContent-Disposition: form-data; name=\"root\"\r\n\r\ngcodes\r\n--BND\r\n"))
        XCTAssertTrue(text.contains("filename=\"a %22b%22.gcode\""))
        XCTAssertTrue(String(decoding: body.suffix(20), as: UTF8.self).hasSuffix("\r\n--BND--\r\n"))
        // le contenu du fichier est présent, intact, entre l'en-tête et le pied
        let headerEnd = body.range(of: Data("\r\n\r\n".utf8), options: [], in: body.range(of: Data("filename=".utf8))!.upperBound..<body.endIndex)!.upperBound
        XCTAssertEqual(body[headerEnd..<(headerEnd + payload.count)], payload)
    }
}
