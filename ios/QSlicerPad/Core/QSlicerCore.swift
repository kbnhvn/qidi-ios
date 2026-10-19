//
//  QSlicerCore.swift
//  Enveloppe Swift autour de l'ABI C du moteur QIDISlicer.
//
//  Le cœur libslic3r n'est pas réentrant : un seul contexte, un seul slicing à
//  la fois (l'ABI renvoie QSID_ERR_BUSY sinon). Les appels sont bloquants et
//  doivent être faits hors du thread principal ; la progression est rapportée
//  depuis le thread de slicing.
//

import Foundation

/// Erreurs remontées par l'ABI C.
enum SlicerCoreError: LocalizedError {
    case unavailable
    case invalidArgument(String)
    case io(String)
    case sliceFailed(String)
    case canceled
    case busy
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:            return "Le moteur de slicing n'a pas pu être initialisé."
        case .invalidArgument(let m): return "Argument invalide : \(m)"
        case .io(let m):              return "Entrée/sortie : \(m)"
        case .sliceFailed(let m):     return "Échec du slicing : \(m)"
        case .canceled:               return "Slicing annulé."
        case .busy:                   return "Un slicing est déjà en cours."
        case .engine(let m):          return m
        }
    }
}

/// Encapsule la closure de progression : Swift ne peut pas capturer dans une
/// fonction C, on passe donc un pointeur vers cet objet via `user`.
private final class ProgressBox {
    let handler: (Int32, String) -> Void
    init(_ handler: @escaping (Int32, String) -> Void) { self.handler = handler }
}

final class SlicerCore {
    private var context: OpaquePointer?

    init(resourcesDirectory: URL, dataDirectory: URL) throws {
        let created = resourcesDirectory.path.withCString { res in
            dataDirectory.path.withCString { data in
                qsid_create(res, data)
            }
        }
        guard let created else { throw SlicerCoreError.unavailable }
        self.context = created
    }

    deinit {
        if let context { qsid_destroy(context) }
    }

    /// Version du moteur, telle que compilée.
    static var version: String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard Int(qsid_version(&buffer, buffer.count)) == QSID_OK else { return "inconnue" }
        return String(cString: buffer)
    }

    /// Slice `model` avec le profil `config` (ini) vers `output`.
    /// - Parameter progress: appelée depuis un thread de fond (percent 0…100, message).
    /// Fonction bloquante : à appeler hors du thread principal.
    func slice(model: URL, config: URL?, output: URL,
               progress: @escaping (Int32, String) -> Void) throws {
        guard let context else { throw SlicerCoreError.unavailable }

        var error = [CChar](repeating: 0, count: 512)
        let box = ProgressBox(progress)
        let user = Unmanaged.passUnretained(box).toOpaque()

        let status: Int32
        if let configPath = config?.path {
            status = model.path.withCString { m in
                configPath.withCString { c in
                    output.path.withCString { o in
                        qsid_slice_async(context, m, c, o, { percent, message, user in
                            guard let user else { return }
                            let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
                            box.handler(percent, message.map { String(cString: $0) } ?? "")
                        }, user, &error, error.count)
                    }
                }
            }
        } else {
            status = model.path.withCString { m in
                output.path.withCString { o in
                    qsid_slice_async(context, m, nil, o, { percent, message, user in
                        guard let user else { return }
                        let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
                        box.handler(percent, message.map { String(cString: $0) } ?? "")
                    }, user, &error, error.count)
                }
            }
        }

        try Self.check(status, error)
    }

    /// Demande l'annulation du slicing en cours (thread-safe).
    func cancel() {
        guard let context else { return }
        qsid_cancel(context)
    }

    /// Exporte n'importe quel modèle supporté vers un STL (pour le visualiseur).
    func exportSTL(model: URL, output: URL) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        var error = [CChar](repeating: 0, count: 512)
        let status = model.path.withCString { m in
            output.path.withCString { o in
                qsid_export_stl(context, m, o, &error, error.count)
            }
        }
        try Self.check(status, error)
    }

    // MARK: - ABI v3 : presets, configuration, scène, slicing de la scène
    //
    // Toutes ces fonctions doivent être appelées depuis la même file série (le
    // moteur n'est pas réentrant) ; seules `cancel()` et `isSlicing` peuvent l'être
    // depuis un autre thread.

    /// Appelle une fonction C qui retourne un JSON alloué, et le convertit en String.
    private func jsonCall(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<CChar>, Int) -> Int32) throws -> String {
        var error = [CChar](repeating: 0, count: 512)
        var out: UnsafeMutablePointer<CChar>?
        let status = body(&out, &error, error.count)
        try Self.check(status, error)
        guard let out else { return "" }
        defer { qsid_free(out) }
        return String(cString: out)
    }

    private func errorCall(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 512)
        let status = body(&error, error.count)
        try Self.check(status, error)
    }

    func loadPresets(vendorINI: URL) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try errorCall { e, n in vendorINI.path.withCString { qsid_presets_load(context, $0, e, n) } }
    }

    /// kind : "printer" | "print" | "filament" — presets compatibles avec la sélection courante.
    func presets(kind: String) throws -> [String] {
        guard let context else { throw SlicerCoreError.unavailable }
        let json = try jsonCall { out, e, n in kind.withCString { qsid_presets_list(context, $0, out, e, n) } }
        return try SceneJSON.decodeStrings(json)
    }

    struct PresetSelection: Equatable {
        var printer: String
        var print: String
        var filament: String
    }

    /// Le moteur remplace un preset devenu incompatible : la valeur retournée est celle retenue.
    @discardableResult
    func selectPresets(printer: String?, print: String?, filament: String?) throws -> PresetSelection {
        guard let context else { throw SlicerCoreError.unavailable }
        func c(_ s: String?) -> String { s ?? "" }
        let json = try jsonCall { out, e, n in
            c(printer).withCString { p in c(print).withCString { r in c(filament).withCString { f in
                qsid_presets_select(context, p, r, f, out, e, n)
            } } }
        }
        let d = try SceneJSON.decodeDictionary(json)
        return PresetSelection(printer: d["printer"] ?? "", print: d["print"] ?? "", filament: d["filament"] ?? "")
    }

    func loadConfigINI(_ url: URL) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try errorCall { e, n in url.path.withCString { qsid_config_load_ini(context, $0, e, n) } }
    }

    func baseConfig() throws -> [String: String] { try configDictionary(qsid_config_base) }
    func effectiveConfig() throws -> [String: String] { try configDictionary(qsid_config_effective) }
    func overrides() throws -> [String: String] { try configDictionary(qsid_config_overrides) }

    private func configDictionary(_ fn: (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32) throws -> [String: String] {
        guard let context else { throw SlicerCoreError.unavailable }
        var out: UnsafeMutablePointer<CChar>?
        let status = fn(context, &out)
        try Self.check(status)
        guard let out else { return [:] }
        defer { qsid_free(out) }
        return try SceneJSON.decodeDictionary(String(cString: out))
    }

    func setConfig(_ key: String, _ value: String) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try errorCall { e, n in key.withCString { k in value.withCString { v in qsid_config_set(context, k, v, e, n) } } }
    }

    /// `key == nil` : retire toutes les surcharges.
    func resetConfig(_ key: String? = nil) {
        guard let context else { return }
        if let key { _ = key.withCString { qsid_config_reset(context, $0) } } else { _ = qsid_config_reset(context, nil) }
    }

    /// Définition JSON de toutes les options (clé, type, libellé, aide, bornes, énumérations, mode).
    func configSchemaJSON() throws -> String {
        guard let context else { throw SlicerCoreError.unavailable }
        var out: UnsafeMutablePointer<CChar>?
        try Self.check(qsid_config_schema(context, &out))
        guard let out else { return "[]" }
        defer { qsid_free(out) }
        return String(cString: out)
    }

    // Scène

    func clearScene() throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try Self.check(qsid_scene_clear(context))
    }

    func addToScene(_ url: URL) throws -> SceneAddResult {
        guard let context else { throw SlicerCoreError.unavailable }
        let json = try jsonCall { out, e, n in url.path.withCString { qsid_scene_add(context, $0, out, e, n) } }
        return try SceneJSON.decode(SceneAddResult.self, from: json)
    }

    func sceneInfo() throws -> SceneInfo {
        guard let context else { throw SlicerCoreError.unavailable }
        var out: UnsafeMutablePointer<CChar>?
        try Self.check(qsid_scene_info(context, &out))
        guard let out else { throw SlicerCoreError.engine("scène illisible") }
        defer { qsid_free(out) }
        return try SceneJSON.decode(SceneInfo.self, from: String(cString: out))
    }

    /// Triangles (9 floats chacun) de l'objet, en coordonnées locales.
    func sceneMesh(objectID: UInt64) throws -> [Float] {
        guard let context else { throw SlicerCoreError.unavailable }
        var error = [CChar](repeating: 0, count: 512)
        var xyz: UnsafeMutablePointer<Float>?
        var count = 0
        try Self.check(qsid_scene_mesh(context, objectID, &xyz, &count, &error, error.count), error)
        guard let xyz else { return [] }
        defer { qsid_free(xyz) }
        return Array(UnsafeBufferPointer(start: xyz, count: count * 9))
    }

    func setTransform(objectID: UInt64, instance: Int = 0,
                      offset: [Double]? = nil, rotationDeg: [Double]? = nil, scale: [Double]? = nil,
                      dropToBed: Bool = false) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        func call(_ o: UnsafePointer<Double>?, _ r: UnsafePointer<Double>?, _ s: UnsafePointer<Double>?) -> Int32 {
            qsid_scene_set_transform(context, objectID, Int32(instance), o, r, s, dropToBed ? 1 : 0)
        }
        func with3(_ v: [Double]?, _ body: (UnsafePointer<Double>?) -> Int32) -> Int32 {
            guard let v, v.count == 3 else { return body(nil) }
            return v.withUnsafeBufferPointer { body($0.baseAddress) }
        }
        let status = with3(offset) { o in with3(rotationDeg) { r in with3(scale) { s in call(o, r, s) } } }
        try Self.check(status)
    }

    func removeObject(_ id: UInt64) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try Self.check(qsid_scene_remove(context, id))
    }

    func setInstanceCount(objectID: UInt64, count: Int) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try Self.check(qsid_scene_set_instances(context, objectID, Int32(count)))
    }

    func arrangeScene() throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try Self.check(qsid_scene_arrange(context))
    }

    func dropToBed(objectID: UInt64) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        try Self.check(qsid_scene_drop_to_bed(context, objectID))
    }

    func layOnFace(objectID: UInt64, instance: Int = 0, triangle: Int) throws {
        guard let context else { throw SlicerCoreError.unavailable }
        var error = [CChar](repeating: 0, count: 512)
        let status = qsid_scene_lay_on_face(context, objectID, Int32(instance), triangle, &error, error.count)
        try Self.check(status, error)
    }

    /// Slice la scène avec la configuration effective ; retourne le résumé (durée, filament…).
    func sliceScene(output: URL, progress: @escaping (Int32, String) -> Void) throws -> SliceSummary {
        guard let context else { throw SlicerCoreError.unavailable }
        var error = [CChar](repeating: 0, count: 512)
        let box = ProgressBox(progress)
        let user = Unmanaged.passUnretained(box).toOpaque()
        var summary: UnsafeMutablePointer<CChar>?
        let status = output.path.withCString { o in
            qsid_slice_scene(context, o, { percent, message, user in
                guard let user else { return }
                let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
                box.handler(percent, message.map { String(cString: $0) } ?? "")
            }, user, &summary, &error, error.count)
        }
        try Self.check(status, error)
        guard let summary else { throw SlicerCoreError.engine("résumé de slicing absent") }
        defer { qsid_free(summary) }
        return try SceneJSON.decode(SliceSummary.self, from: String(cString: summary))
    }

    /// Mouvements du dernier slicing.
    func gcodeMoves() throws -> [qsid_move] {
        guard let context else { throw SlicerCoreError.unavailable }
        var moves: UnsafeMutablePointer<qsid_move>?
        var count = 0
        try Self.check(qsid_gcode_moves(context, &moves, &count))
        guard let moves else { return [] }
        defer { qsid_free(moves) }
        return Array(UnsafeBufferPointer(start: moves, count: count))
    }

    private static func check(_ status: Int32) throws { try check(status, [0]) }

    private static func check(_ status: Int32, _ error: [CChar]) throws {
        switch Int(status) {
        case QSID_OK:               return
        case QSID_ERR_ARG:          throw SlicerCoreError.invalidArgument(String(cString: error))
        case QSID_ERR_IO:           throw SlicerCoreError.io(String(cString: error))
        case QSID_ERR_SLICE_FAILED: throw SlicerCoreError.sliceFailed(String(cString: error))
        case QSID_ERR_CANCELED:     throw SlicerCoreError.canceled
        case QSID_ERR_BUSY:         throw SlicerCoreError.busy
        case QSID_ERR_NO_CONTEXT:   throw SlicerCoreError.unavailable
        default:                    throw SlicerCoreError.engine(String(cString: error))
        }
    }
}

extension GCodeMove {
    /// Conversion depuis la structure C de l'ABI.
    init(_ m: qsid_move) {
        self.init(x: m.x, y: m.y, z: m.z, feedrate: m.feedrate, width: m.width, height: m.height,
                  fanSpeed: m.fan_speed, temperature: m.temperature, time: m.time, eDelta: m.e_delta,
                  layer: m.layer, type: m.type, role: m.role)
    }
}
