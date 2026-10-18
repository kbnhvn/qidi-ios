//
//  QSlicerCore.swift
//  Enveloppe Swift mince autour de l'ABI C du moteur QIDISlicer.
//
//  Le cœur libslic3r n'est pas réentrant : un seul contexte, appels sérialisés.
//  L'appel qsid_slice() est bloquant (la v1 du cœur n'expose ni progression ni
//  annulation) : il est donc exécuté hors du thread principal.
//

import Foundation

/// Erreurs remontées par l'ABI C.
enum SlicerCoreError: LocalizedError {
    case unavailable
    case invalidArgument(String)
    case io(String)
    case sliceFailed(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:              return "Le moteur de slicing n'a pas pu être initialisé."
        case .invalidArgument(let m):   return "Argument invalide : \(m)"
        case .io(let m):                return "Entrée/sortie : \(m)"
        case .sliceFailed(let m):       return "Échec du slicing : \(m)"
        case .engine(let m):            return m
        }
    }
}

final class SlicerCore {
    private var context: OpaquePointer?

    /// - Parameters:
    ///   - resourcesDirectory: dossier des ressources du cœur (profils) dans le bundle.
    ///   - dataDirectory: dossier inscriptible du conteneur de l'app.
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
        // Les constantes du C (enum anonyme) sont importées en Int : on ramène le
        // code de retour (Int32) au même type avant comparaison.
        guard Int(qsid_version(&buffer, buffer.count)) == QSID_OK else { return "inconnue" }
        return String(cString: buffer)
    }

    /// Slice `model` avec le profil `config` et écrit le G-code dans `output`.
    /// Fonction bloquante : à appeler hors du thread principal.
    func slice(model: URL, config: URL?, output: URL) throws {
        guard let context else { throw SlicerCoreError.unavailable }

        var error = [CChar](repeating: 0, count: 512)

        // Les pointeurs C ne vivent que dans leur closure : on imbrique donc les
        // appels, plutôt que d'extraire un pointeur d'une closure (qui deviendrait
        // un pointeur pendant).
        let status: Int32
        if let configPath = config?.path {
            status = model.path.withCString { modelPtr in
                configPath.withCString { configPtr in
                    output.path.withCString { outputPtr in
                        qsid_slice(context, modelPtr, configPtr, outputPtr, &error, error.count)
                    }
                }
            }
        } else {
            status = model.path.withCString { modelPtr in
                output.path.withCString { outputPtr in
                    qsid_slice(context, modelPtr, nil, outputPtr, &error, error.count)
                }
            }
        }

        switch Int(status) {
        case QSID_OK:
            return
        case QSID_ERR_ARG:
            throw SlicerCoreError.invalidArgument(String(cString: error))
        case QSID_ERR_IO:
            throw SlicerCoreError.io(String(cString: error))
        case QSID_ERR_SLICE_FAILED:
            throw SlicerCoreError.sliceFailed(String(cString: error))
        default:
            throw SlicerCoreError.engine(String(cString: error))
        }
    }
}
