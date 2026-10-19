//
//  SceneTypes.swift
//  Types décodés depuis le JSON de l'ABI v3 (qsid_scene_info, qsid_slice_scene…).
//  Pur Foundation : testé sous Linux (ios/QSlicerKit) contre des sorties réelles du moteur.
//

import Foundation

struct SceneBed: Decodable, Equatable {
    /// Contour du plateau (mm), sommets [x, y].
    let shape: [[Double]]
    let maxHeight: Double

    var minX: Double { shape.map { $0[0] }.min() ?? 0 }
    var maxX: Double { shape.map { $0[0] }.max() ?? 0 }
    var minY: Double { shape.map { $0[1] }.min() ?? 0 }
    var maxY: Double { shape.map { $0[1] }.max() ?? 0 }
    var width: Double { maxX - minX }
    var depth: Double { maxY - minY }
}

struct SceneInstance: Decodable, Equatable {
    var offset: [Double]
    var rotationDeg: [Double]
    var scale: [Double]
    /// Boîte englobante monde (mm).
    var min: [Double]
    var max: [Double]
    var outside: Bool
    /// Matrice 4×4 colonne-majeur (repère monde de l'imprimante).
    var matrix: [Double]

    var size: [Double] { zip(max, min).map { $0 - $1 } }
}

struct SceneObject: Decodable, Equatable, Identifiable {
    let id: UInt64
    var name: String
    var triangles: Int
    var localMin: [Double]
    var localMax: [Double]
    var instances: [SceneInstance]

    var localSize: [Double] { zip(localMax, localMin).map { $0 - $1 } }
}

struct SceneInfo: Decodable, Equatable {
    var bed: SceneBed
    var objects: [SceneObject]

    var hasObjectOutsideBed: Bool {
        objects.contains { $0.instances.contains { $0.outside } }
    }
}

/// Alertes remontées au chargement d'un fichier (comme les notifications du bureau).
struct SceneAlerts: Decodable, Equatable {
    var deletedObjects: Int
    var multipart: Bool
    var savedInMeters: Bool
    var imperial: Bool

    var isEmpty: Bool { deletedObjects == 0 && !multipart && !savedInMeters && !imperial }
}

struct SceneAddResult: Decodable, Equatable {
    var added: [UInt64]
    var alerts: SceneAlerts
}

struct SliceSummary: Decodable, Equatable {
    struct Role: Decodable, Equatable {
        var role: Int
        var name: String
        var timeS: Double
        var filamentM: Double
        var filamentG: Double
    }

    var timeNormalS: Double
    var timeSilentS: Double
    var timeNormal: String
    var timeSilent: String
    var filamentMm: Double
    var filamentCm3: Double
    var filamentG: Double
    var cost: Double
    var toolchanges: Int
    var layers: Int
    var moves: Int
    var roles: [Role]
    var warnings: [String]
}

enum SceneJSON {
    /// Décode une sortie JSON de l'ABI (clés en snake_case).
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(text.utf8))
    }

    static func decodeStrings(_ text: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(text.utf8))
    }

    static func decodeDictionary(_ text: String) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    }
}

/// « 1 h 12 min », « 17 min », « 35 s ».
func formatDuration(seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h) h \(String(format: "%02d", m)) min" }
    if m > 0 { return "\(m) min" }
    return "\(s) s"
}
