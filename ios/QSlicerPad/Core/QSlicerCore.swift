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

    private static func check(_ status: Int32, _ error: [CChar]) throws {
        switch Int(status) {
        case QSID_OK:               return
        case QSID_ERR_ARG:          throw SlicerCoreError.invalidArgument(String(cString: error))
        case QSID_ERR_IO:           throw SlicerCoreError.io(String(cString: error))
        case QSID_ERR_SLICE_FAILED: throw SlicerCoreError.sliceFailed(String(cString: error))
        case QSID_ERR_CANCELED:     throw SlicerCoreError.canceled
        case QSID_ERR_BUSY:         throw SlicerCoreError.busy
        default:                    throw SlicerCoreError.engine(String(cString: error))
        }
    }
}
