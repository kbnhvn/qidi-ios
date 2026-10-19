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

/// Volume d'un objet : pièce du modèle, ou modificateur / bloqueur / forceur de supports.
struct SceneVolume: Decodable, Equatable, Identifiable {
    let id: UInt64
    var name: String
    /// "part" | "modifier" | "blocker" | "enforcer"
    var kind: String
    /// Position et dimensions dans le repère local de l'objet (mm).
    var offset: [Double]
    var size: [Double]
    var triangles: Int
    var config: [String: String]

    var isModifier: Bool { kind != "part" }
}

/// Plage de hauteurs [min, max] (mm) avec ses propres réglages.
struct SceneLayerRange: Decodable, Equatable, Identifiable {
    var min: Double
    var max: Double
    var config: [String: String]
    var id: String { "\(min)-\(max)" }
}

struct SceneObject: Decodable, Equatable, Identifiable {
    let id: UInt64
    var name: String
    var triangles: Int
    var localMin: [Double]
    var localMax: [Double]
    var instances: [SceneInstance]
    /// Réglages propres à l'objet (par-dessus le preset).
    var config: [String: String] = [:]
    var volumes: [SceneVolume] = []
    var layerRanges: [SceneLayerRange] = []

    var localSize: [Double] { zip(localMax, localMin).map { $0 - $1 } }
    var modifiers: [SceneVolume] { volumes.filter(\.isModifier) }
    /// Vrai si l'objet porte au moins un réglage, modificateur ou plage de couches.
    var hasCustomSettings: Bool { !config.isEmpty || !modifiers.isEmpty || !layerRanges.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, name, triangles, localMin, localMax, instances, config, volumes, layerRanges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        triangles = try c.decode(Int.self, forKey: .triangles)
        localMin = try c.decode([Double].self, forKey: .localMin)
        localMax = try c.decode([Double].self, forKey: .localMax)
        instances = try c.decode([SceneInstance].self, forKey: .instances)
        config = try c.decodeIfPresent([String: String].self, forKey: .config) ?? [:]
        volumes = try c.decodeIfPresent([SceneVolume].self, forKey: .volumes) ?? []
        layerRanges = try c.decodeIfPresent([SceneLayerRange].self, forKey: .layerRanges) ?? []
    }

    init(id: UInt64, name: String, triangles: Int, localMin: [Double], localMax: [Double], instances: [SceneInstance]) {
        self.id = id; self.name = name; self.triangles = triangles
        self.localMin = localMin; self.localMax = localMax; self.instances = instances
    }
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

/// Résultat d'une coupe : identifiants des objets créés.
struct SceneCutResult: Decodable, Equatable {
    var objects: [UInt64]
}

/// Résultat d'une simplification de maillage.
struct SceneSimplifyResult: Decodable, Equatable {
    var before: Int
    var after: Int
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
