//
//  SlicerModel.swift
//  État de l'app : fichier importé, profil, exécution du slicing.
//
//  Le slicing se fait *dans le processus* (ABI C) — pas de serveur, pas de
//  sous-processus. Tout est local : les seuls fichiers écrits le sont dans le
//  conteneur de l'app.
//

import Foundation
import SwiftUI

@MainActor
final class SlicerModel: ObservableObject {

    // MARK: Sortie publiée

    @Published private(set) var catalog = QIDIProfileCatalog(printerModels: [], vendorName: nil)
    @Published var selectedPrinter: String = ""
    @Published private(set) var importedProfile: URL?
    @Published private(set) var importedModel: URL?
    @Published private(set) var isSlicing = false
    @Published private(set) var statusLine: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var output: SliceOutput?

    struct SliceOutput: Identifiable {
        let id = UUID()
        let url: URL
        let lines: Int
        let layers: Int
        let sizeBytes: Int64
        let seconds: Double
    }

    // MARK: Chemins

    /// Ressources du cœur (profils vendor), dans le bundle.
    private let resourcesDirectory: URL = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("qidi") {
            return url
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
    }()

    /// Répertoire inscriptible du conteneur, pour les caches/config du cœur.
    private let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("qidi-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Exports visibles dans Fichiers (UIFileSharingEnabled).
    private let exportsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var core: SlicerCore?

    /// Configuration générique embarquée, utilisée si aucun profil n'est importé.
    var bundledGenericConfig: URL? {
        Bundle.main.url(forResource: "qidi_generic_fff", withExtension: "ini", subdirectory: "qidi/generic")
    }

    var engineVersion: String { SlicerCore.version }

    var activeProfile: URL? { importedProfile ?? bundledGenericConfig }

    var activeProfileLabel: String {
        if let importedProfile = importedProfile { return importedProfile.lastPathComponent }
        return "Configuration générique embarquée (dépannage)"
    }

    // MARK: Cycle de vie

    init() {
        catalog = QIDIProfileCatalog.load()
        if selectedPrinter.isEmpty { selectedPrinter = catalog.printerModels.first ?? "" }
        do {
            core = try SlicerCore(resourcesDirectory: resourcesDirectory, dataDirectory: dataDirectory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Import

    /// Importe un fichier choisi par l'utilisateur dans le conteneur (les URL du
    /// sélecteur sont éphémères : il faut copier).
    private func importFile(from url: URL, into directory: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    func importModel(from url: URL) {
        errorMessage = nil
        output = nil
        do {
            importedModel = try importFile(from: url, into: dataDirectory.appendingPathComponent("models"))
        } catch {
            errorMessage = "Import du modèle impossible : \(error.localizedDescription)"
        }
    }

    func importProfile(from url: URL) {
        errorMessage = nil
        do {
            importedProfile = try importFile(from: url, into: dataDirectory.appendingPathComponent("profiles"))
        } catch {
            errorMessage = "Import du profil impossible : \(error.localizedDescription)"
        }
    }

    func clearProfile() {
        importedProfile = nil
    }

    // MARK: Slicing

    func slice() {
        guard let model = importedModel else {
            errorMessage = "Importez d'abord un modèle (STL, 3MF, OBJ)."
            return
        }
        guard let core else {
            errorMessage = "Le moteur de slicing n'est pas disponible."
            return
        }

        let output = exportsDirectory
            .appendingPathComponent(model.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("gcode")

        isSlicing = true
        errorMessage = nil
        statusLine = "Slicing en cours… (le cœur n'expose pas encore de progression)"
        let config = activeProfile
        let started = Date()

        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try core.slice(model: model, config: config, output: output)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                let stats = Self.inspect(gcode: output)
                self.output = SliceOutput(url: output,
                                          lines: stats.lines,
                                          layers: stats.layers,
                                          sizeBytes: stats.bytes,
                                          seconds: Date().timeIntervalSince(started))
                self.statusLine = "Terminé en \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusLine = nil
            }
            self.isSlicing = false
        }
    }

    private static func inspect(gcode url: URL) -> (lines: Int, layers: Int, bytes: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0, 0) }
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        var lines = 0
        var layers = 0
        data.split(separator: 0x0A).forEach { line in
            lines += 1
            if line.starts(with: Array(";LAYER_CHANGE".utf8)) { layers += 1 }
        }
        return (lines, layers, Int64(data.count))
    }
}
