//
//  SlicerModel.swift
//  État de l'app : profils, modèle importé, slicing (avec progression et
//  annulation), aperçu, envoi à l'imprimante.
//

import Foundation
import SwiftUI

@MainActor
final class SlicerModel: ObservableObject {

    // MARK: Profils

    @Published private(set) var catalog = QIDIProfileCatalog(sections: [:], vendorName: nil)
    @Published var selectedPrinter: String = "" {
        didSet { if selectedPrinter != oldValue { selectedPrint = catalog.printPresets(for: selectedPrinter).first ?? "" } }
    }
    @Published var selectedPrint: String = ""
    @Published var selectedFilament: String = ""
    /// Profil importé (export du bureau) : prioritaire sur le bundle si présent.
    @Published private(set) var importedProfile: URL?

    // MARK: Modèle et résultat

    @Published private(set) var importedModel: URL?
    @Published private(set) var mesh: STLMesh?
    @Published private(set) var preview: GCodePreview?
    @Published private(set) var output: SliceOutput?

    struct SliceOutput: Identifiable {
        let id = UUID()
        let url: URL
        let lines: Int
        let layers: Int
        let sizeBytes: Int64
        let seconds: Double
    }

    /// Incrémenté quand la langue change : l'interface est reconstruite.
    @Published var languageVersion = 0

    // MARK: Exécution

    @Published private(set) var isSlicing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText: String = ""
    @Published private(set) var statusLine: String?
    @Published private(set) var errorMessage: String?

    // MARK: Imprimante (Moonraker)

    @Published var moonraker: MoonrakerConfig = MoonrakerConfig() {
        didSet { persistMoonraker() }
    }
    @Published private(set) var isUploading = false
    @Published private(set) var uploadStatus: String?

    // MARK: Chemins

    private let resourcesDirectory: URL = {
        Bundle.main.resourceURL?.appendingPathComponent("qidi")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }()

    private let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("qidi-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let exportsDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let workDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qslicerpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var core: SlicerCore?

    private enum DefaultsKey {
        static let printer = "qsid.printer"
        static let print = "qsid.print"
        static let filament = "qsid.filament"
        static let moonraker = "qsid.moonraker"
    }

    // MARK: Cycle de vie

    init() {
        catalog = QIDIProfileCatalog.load()
        restoreSelection()
        restoreMoonraker()

        do {
            core = try SlicerCore(resourcesDirectory: resourcesDirectory, dataDirectory: dataDirectory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var engineVersion: String { SlicerCore.version }

    var hasEmbeddedProfiles: Bool { !catalog.printers.isEmpty }

    /// Configuration réellement utilisée : le profil importé, sinon les presets.
    var activeProfileLabel: String {
        if let importedProfile { return importedProfile.lastPathComponent }
        if hasEmbeddedProfiles && !selectedPrinter.isEmpty {
            let filament = selectedFilament.isEmpty ? "" : " / \(selectedFilament)"
            return "\(selectedPrinter) · \(selectedPrint)\(filament)"
        }
        return "Configuration générique embarquée (dépannage)"
    }

    private var bundledGenericConfig: URL? {
        Bundle.main.url(forResource: "qidi_generic_fff", withExtension: "ini", subdirectory: "qidi/generic")
    }

    // MARK: Sélection persistée

    private func restoreSelection() {
        let d = UserDefaults.standard
        let printers = catalog.printers
        let stored = d.string(forKey: DefaultsKey.printer)
        selectedPrinter = (stored.flatMap { printers.contains($0) ? $0 : nil }) ?? printers.first ?? ""

        let prints = catalog.printPresets(for: selectedPrinter)
        let storedPrint = d.string(forKey: DefaultsKey.print)
        selectedPrint = (storedPrint.flatMap { prints.contains($0) ? $0 : nil }) ?? prints.first ?? ""

        let filaments = catalog.filamentPresets(for: selectedPrinter)
        let storedFilament = d.string(forKey: DefaultsKey.filament)
        selectedFilament = (storedFilament.flatMap { filaments.contains($0) ? $0 : nil }) ?? filaments.first ?? ""
    }

    func persistSelection() {
        let d = UserDefaults.standard
        d.set(selectedPrinter, forKey: DefaultsKey.printer)
        d.set(selectedPrint, forKey: DefaultsKey.print)
        d.set(selectedFilament, forKey: DefaultsKey.filament)
    }

    private func restoreMoonraker() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.moonraker),
              let config = try? JSONDecoder().decode(MoonrakerConfig.self, from: data) else { return }
        moonraker = config
    }

    private func persistMoonraker() {
        guard let data = try? JSONEncoder().encode(moonraker) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.moonraker)
    }

    // MARK: Import

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
        preview = nil
        do {
            let copy = try importFile(from: url, into: dataDirectory.appendingPathComponent("models"))
            importedModel = copy
            loadMesh(for: copy)
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

    func clearProfile() { importedProfile = nil }

    // MARK: Aperçu du modèle

    /// Charge un maillage pour le visualiseur. Un STL est lu directement ; pour
    /// les autres formats, le moteur l'exporte en STL (in-process).
    private func loadMesh(for model: URL) {
        mesh = nil
        let ext = model.pathExtension.lowercased()
        if ext == "stl" {
            if let loaded = try? STLLoader.load(url: model) { mesh = loaded; return }
        }
        guard let core else { return }
        let stlURL = workDirectory.appendingPathComponent(model.deletingPathExtension().lastPathComponent + ".stl")
        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { try core.exportSTL(model: model, output: stlURL); continuation.resume() }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                if let loaded = try? STLLoader.load(url: stlURL) {
                    self.mesh = loaded
                }
            } catch {
                // L'aperçu est un confort : ne pas masquer l'erreur de slicing.
                print("aperçu indisponible : \(error.localizedDescription)")
            }
        }
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
        guard !isSlicing else { return }

        var config = bundledGenericConfig
        do {
            if let importedProfile {
                config = importedProfile
            } else if hasEmbeddedProfiles, !selectedPrinter.isEmpty, !selectedPrint.isEmpty {
                let url = workDirectory.appendingPathComponent("preset.ini")
                try catalog.writeConfig(printer: selectedPrinter,
                                        print: selectedPrint,
                                        filament: selectedFilament.isEmpty ? nil : selectedFilament,
                                        to: url)
                config = url
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let outputURL = exportsDirectory
            .appendingPathComponent(model.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("gcode")

        isSlicing = true
        progress = 0
        progressText = "Préparation…"
        statusLine = nil
        errorMessage = nil
        let started = Date()

        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try core.slice(model: model, config: config, output: outputURL) { percent, text in
                                Task { @MainActor in
                                    if percent >= 0 { self.progress = Double(percent) / 100.0 }
                                    self.progressText = text
                                }
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                let elapsed = Date().timeIntervalSince(started)
                let stats = Self.streamStats(gcode: outputURL)
                self.output = SliceOutput(url: outputURL,
                                          lines: stats.lines,
                                          layers: stats.layers,
                                          sizeBytes: stats.bytes,
                                          seconds: elapsed)
                self.statusLine = "Terminé en \(String(format: "%.1f", elapsed)) s"
                self.progress = 1
                self.progressText = "Terminé"
                self.preview = try? GCodePreview.parse(url: outputURL)
            } catch SlicerCoreError.canceled {
                self.statusLine = "Slicing annulé."
                self.progress = 0
                self.progressText = ""
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusLine = nil
            }
            self.isSlicing = false
        }
    }

    func cancel() {
        core?.cancel()
    }

    /// Statistiques du G-code en *streaming* (un fichier peut faire des centaines de Mo).
    private static func streamStats(gcode url: URL) -> (lines: Int, layers: Int, bytes: Int64) {
        guard let stream = InputStream(url: url) else { return (0, 0, 0) }
        stream.open()
        defer { stream.close() }

        var lines = 0, layers = 0, bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var atLineStart = true
        var matched = 0
        let needle = Array(";LAYER_CHANGE".utf8)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            bytes += Int64(read)
            for i in 0..<read {
                let byte = buffer[i]
                if atLineStart {
                    if matched < needle.count && byte == needle[matched] {
                        matched += 1
                    } else {
                        matched = (byte == needle[0]) ? 1 : 0
                    }
                    atLineStart = false
                }
                if byte == 0x0A {
                    lines += 1
                    atLineStart = true
                    if matched == needle.count { layers += 1 }
                    matched = 0
                }
            }
        }
        return (lines, layers, bytes)
    }

    // MARK: Envoi à l'imprimante

    func uploadAndPrint() {
        guard let output else { return }
        guard moonraker.isConfigured else {
            errorMessage = MoonrakerError.notConfigured.localizedDescription
            return
        }
        isUploading = true
        uploadStatus = "Envoi…"
        errorMessage = nil

        let client = MoonrakerClient(config: moonraker)
        let file = output.url
        Task {
            do {
                try await client.upload(file: file, filename: file.lastPathComponent)
                self.uploadStatus = "Envoi terminé, démarrage…"
                try await client.startPrint(filename: file.lastPathComponent)
                self.uploadStatus = "Impression lancée."
            } catch {
                self.uploadStatus = nil
                self.errorMessage = error.localizedDescription
            }
            self.isUploading = false
        }
    }

    func refreshPrinterStatus() {
        guard moonraker.isConfigured else { return }
        let client = MoonrakerClient(config: moonraker)
        Task {
            do {
                let status = try await client.status()
                self.uploadStatus = "\(status.state) — \(Int(status.progress * 100)) %"
            } catch {
                self.uploadStatus = error.localizedDescription
            }
        }
    }
}
