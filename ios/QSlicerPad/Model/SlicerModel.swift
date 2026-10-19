//
//  SlicerModel.swift
//  État de l'app : presets (moteur), réglages, scène posée sur le plateau,
//  slicing (progression, annulation), aperçu G-code, envoi à l'imprimante.
//
//  Le moteur (libslic3r) n'est pas réentrant : tous les appels passent par une
//  file série (`onEngine`). La vue ne parle jamais au moteur directement ; elle
//  applique les gestes localement (fluide) et valide auprès du moteur à la fin.
//

import Foundation
import SwiftUI
import UIKit   // UIApplication : écran éveillé + tâche d'arrière-plan

/// Où le modèle trouve ses fichiers. Dans l'app : le bundle et le conteneur ; dans les tests
/// de bout en bout (Linux) : des dossiers temporaires et les ressources du dépôt.
struct SlicerLocations {
    /// Racine « qidi » (profils vendor, modèles de calibration), lue par le moteur.
    var resourcesDirectory: URL
    var dataDirectory: URL
    var exportsDirectory: URL
    var workDirectory: URL
    var configPagesURL: URL?
    var configFrenchURL: URL?

    var vendorINI: URL { resourcesDirectory.appendingPathComponent("profiles/QIDITechnology.ini") }
    var calibrationDirectory: URL { resourcesDirectory.appendingPathComponent("calib") }

    static var bundle: SlicerLocations {
        let fm = FileManager.default
        func dir(_ url: URL) -> URL {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return SlicerLocations(
            resourcesDirectory: Bundle.main.resourceURL?.appendingPathComponent("qidi")
                ?? URL(fileURLWithPath: NSTemporaryDirectory()),
            dataDirectory: dir(support.appendingPathComponent("qidi-data", isDirectory: true)),
            exportsDirectory: dir(docs.appendingPathComponent("Exports", isDirectory: true)),
            workDirectory: dir(fm.temporaryDirectory.appendingPathComponent("qslicerpad", isDirectory: true)),
            configPagesURL: Bundle.main.url(forResource: "config_pages", withExtension: "json"),
            configFrenchURL: Bundle.main.url(forResource: "config_fr", withExtension: "json"))
    }
}

@MainActor
final class SlicerModel: ObservableObject {

    // MARK: Types

    struct SliceOutput: Identifiable {
        let id = UUID()
        let url: URL
        let sizeBytes: Int64
        let seconds: Double
    }

    enum Workspace: String, CaseIterable, Identifiable {
        case prepare, preview
        var id: String { rawValue }
    }

    /// Transformation d'une instance, pour annuler/rétablir.
    struct TransformSnapshot: Equatable {
        var objectID: UInt64
        var instance: Int
        var offset: [Double]
        var rotationDeg: [Double]
        var scale: [Double]
    }

    /// Changement de transformation demandé pour une instance.
    struct TransformChange {
        var objectID: UInt64
        var instance = 0
        var offset: [Double]?
        var rotationDeg: [Double]?
        var scale: [Double]?
        var dropToBed = false
    }

    // MARK: Presets (moteur)

    @Published private(set) var printers: [String] = []
    @Published private(set) var printPresets: [String] = []
    @Published private(set) var filamentPresets: [String] = []
    @Published private(set) var selection = SlicerCore.PresetSelection(printer: "", print: "", filament: "")
    /// Profil importé (export du bureau) : remplace les presets tant qu'il est actif.
    @Published private(set) var importedProfile: URL?
    /// Configuration du preset seul (valeurs héritées), sans les réglages de l'utilisateur.
    @Published private(set) var baseConfig: [String: String] = [:]
    @Published private(set) var presetsReady = false

    /// Réglages de l'utilisateur appliqués par-dessus le preset.
    @Published var overrides = SliceOverrides() {
        didSet {
            guard overrides != oldValue else { return }
            persistOverrides()
            scheduleOverridesSync()
        }
    }

    // MARK: Scène

    @Published private(set) var scene: SceneInfo?
    /// Objet principal de la sélection (celui que l'inspecteur détaille). Lui affecter un objet
    /// remplace la sélection par cet objet seul ; nil désélectionne tout.
    var selectedObjectID: UInt64? {
        get { primaryObjectID }
        set {
            if let id = newValue {
                selectedObjectIDs = [id]
                primaryObjectID = id
            } else {
                selectedObjectIDs = []
                primaryObjectID = nil
            }
        }
    }
    @Published private(set) var primaryObjectID: UInt64?
    /// Tous les objets sélectionnés (multi-sélection : ⌘A, mode « Sélection multiple »).
    @Published private(set) var selectedObjectIDs: Set<UInt64> = []
    /// Plan de coupe en cours d'édition (affiché sur le plateau).
    @Published var cutPlane: CutPlane?
    /// Mode « sélection multiple » : un toucher ajoute / retire l'objet de la sélection.
    @Published var multiSelectMode = false
    /// Outil ouvert dans une feuille (simplification, réglages de l'objet).
    @Published var activeTool: ObjectTool?

    enum ObjectTool: Identifiable, Equatable {
        case simplify(UInt64)
        case settings(UInt64)
        var id: String {
            switch self {
            case .simplify(let i): return "simplify-\(i)"
            case .settings(let i): return "settings-\(i)"
            }
        }
    }
    /// Triangles locaux (9 floats chacun) par objet.
    @Published private(set) var meshes: [UInt64: [Float]] = [:]
    @Published private(set) var sceneAlerts: SceneAlerts?
    /// Mode « poser sur une face » : le prochain toucher choisit la face.
    @Published var layOnFaceMode = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // MARK: Calibration

    @Published private(set) var calibration: CalibrationKind?
    /// Aide à la lecture de la calibration en cours (valeur de chaque ligne, formule…).
    @Published private(set) var calibrationLegend: [String] = []
    private var overridesBeforeCalibration: SliceOverrides?

    /// Prépare une impression de calibration : vide le plateau, charge le modèle fourni,
    /// applique les réglages temporaires, les dimensions et les plages de hauteurs.
    /// `endCalibration()` restaure tout.
    func startCalibration(_ kind: CalibrationKind) {
        errorMessage = nil
        let height = Double(baseConfig["max_print_height"] ?? "") ?? 250
        let bed = scene?.bed
        let center: [Double] = bed.map { b -> [Double] in [(b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2] } ?? [135, 135]
        let size: [Double] = bed.map { b -> [Double] in [b.width, b.depth] } ?? [270, 270]
        // configuration effective : preset + réglages de l'utilisateur
        var effective = baseConfig
        for (key, value) in overrides.configEntries(basedOn: baseConfig) { effective[key] = value }
        let plan: CalibrationPlan
        do {
            plan = try Calibration.plan(for: kind, base: effective, maxPrintHeight: height, bedCenter: center, bedSize: size)
        } catch {
            errorMessage = "Calibration impossible : \(error)"
            return
        }
        let url = locations.calibrationDirectory.appendingPathComponent(plan.resource)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Modèle de calibration absent du bundle."
            return
        }
        Task {
            do {
                try await onEngine { try $0.clearScene() }
                meshes.removeAll()
                if overridesBeforeCalibration == nil { overridesBeforeCalibration = overrides }
                for (key, value) in plan.overrides { overrides.set(key, value, base: baseConfig) }
                await overridesSyncTask?.value   // les réglages temporaires doivent être dans le moteur avant la suite
                let added = try await onEngine { try $0.addToScene(url) }
                await refreshScene()
                if let id = added.added.first, let object = scene?.objects.first(where: { $0.id == id }),
                   let instance = object.instances.first {
                    try await shapeCalibrationObject(object, instance: instance, plan: plan)
                }
                if let id = added.added.first {
                    let ranges = plan.layerRanges
                    if !ranges.isEmpty {
                        try await onEngine { core in
                            for r in ranges {
                                try core.setLayerRange(objectID: id, minZ: r.minZ, maxZ: r.maxZ, key: r.key, value: r.value)
                            }
                        }
                    }
                }
                await refreshScene()
                calibration = kind
                calibrationLegend = plan.legend
                selectedObjectID = nil
                output = nil; summary = nil; gcodeMesh = nil; gcodeMoves = []
                workspace = .prepare
                requestCamera(.frame)
            } catch {
                errorMessage = "Calibration impossible : \(error.localizedDescription)"
            }
        }
    }

    /// Met le modèle de calibration aux dimensions et à la position demandées par le plan.
    private func shapeCalibrationObject(_ object: SceneObject, instance: SceneInstance, plan: CalibrationPlan) async throws {
        var wanted: [Double?] = plan.targetSize ?? [nil, nil, nil]
        if let height = plan.targetHeight { wanted[2] = height }
        let local = object.localSize
        var scale = instance.scale
        for axis in 0..<3 {
            if let target = wanted[axis], local[axis] > 1e-6 { scale[axis] = target / local[axis] }
        }
        var offset = instance.offset
        if let position = plan.position {
            for axis in 0..<2 { if let p = position[axis] { offset[axis] = p } }
        }
        let id = object.id
        let newScale = scale, newOffset = offset
        try await onEngine {
            try $0.setTransform(objectID: id, offset: newOffset, scale: newScale, dropToBed: true)
        }
        await refreshScene()
    }

    /// Quitte la calibration : réglages d'origine restaurés, plateau vidé.
    func endCalibration() {
        if let saved = overridesBeforeCalibration { overrides = saved }
        overridesBeforeCalibration = nil
        calibration = nil
        calibrationLegend = []
        clearScene()
    }

    // MARK: Export de la configuration

    @Published private(set) var exportedConfigURL: URL?

    /// Écrit la configuration effective (preset + réglages) en .ini, réimportable dans QIDISlicer
    /// desktop ou dans cette app (« Importer un profil »).
    func prepareConfigExport() {
        Task {
            await overridesSyncTask?.value   // les réglages saisis à l'instant doivent être dans le moteur
            do {
                let config = try await onEngine { try $0.effectiveConfig() }
                let name = selection.print.isEmpty ? "configuration" : presetDisplayName(selection.print)
                let url = workDirectory.appendingPathComponent("\(name).ini")
                var text = "# QSlicerPad — configuration effective (preset + réglages)\n"
                text += config.keys.sorted().map { "\($0) = \(config[$0]!)" }.joined(separator: "\n") + "\n"
                try text.write(to: url, atomically: true, encoding: .utf8)
                exportedConfigURL = url
            } catch {
                errorMessage = "Export impossible : \(error.localizedDescription)"
            }
        }
    }

    // MARK: Préréglages utilisateur (héritent de presets système)

    @Published private(set) var userPresets: [String: UserPreset] = {
        guard let data = UserDefaults.standard.data(forKey: "qsid.userPresets") else { return [:] }
        return UserPresetStore.decode(data)
    }()
    /// Préréglage appliqué en dernier (sert à signaler qu'il a été modifié depuis).
    @Published private(set) var activeUserPreset: String?

    /// Enregistre l'état actuel (presets parents + réglages) sous `name`. Un nom déjà pris est
    /// remplacé si `replacing`, sinon un numéro est ajouté (« enregistrer sous »).
    @discardableResult
    func saveUserPreset(named name: String, replacing: Bool = true) -> String? {
        let existing = Set(userPresets.keys)
        let clean = replacing ? name.trimmingCharacters(in: .whitespacesAndNewlines)
                              : UserPresetStore.uniqueName(name, existing: existing)
        guard !clean.isEmpty else { return nil }
        // un profil .ini importé n'est pas un preset système : pas de parents à mémoriser
        let parents = importedProfile == nil ? selection : SlicerCore.PresetSelection(printer: "", print: "", filament: "")
        userPresets[clean] = UserPreset(name: clean, printer: parents.printer, print: parents.print,
                                        filament: parents.filament, overrides: overrides)
        activeUserPreset = clean
        persistUserPresets()
        return clean
    }

    /// Rétablit les presets parents puis les réglages du préréglage.
    func applyUserPreset(_ name: String) {
        guard let preset = userPresets[name] else { return }
        Task {
            if preset.hasParents {
                await applySelection(printer: preset.printer.isEmpty ? nil : preset.printer,
                                     print: preset.print.isEmpty ? nil : preset.print,
                                     filament: preset.filament.isEmpty ? nil : preset.filament)
            }
            overrides = preset.overrides
            activeUserPreset = name
        }
    }

    /// Vrai si l'état actuel diffère du préréglage actif (réglages ou presets parents).
    var isUserPresetModified: Bool {
        guard let name = activeUserPreset, let preset = userPresets[name] else { return false }
        if overrides != preset.overrides { return true }
        guard preset.hasParents, importedProfile == nil else { return false }
        return selection.printer != preset.printer || selection.print != preset.print || selection.filament != preset.filament
    }

    /// Remplace le préréglage actif par l'état actuel.
    func updateActiveUserPreset() {
        guard let name = activeUserPreset else { return }
        saveUserPreset(named: name)
    }

    func deleteUserPreset(_ name: String) {
        userPresets[name] = nil
        if activeUserPreset == name { activeUserPreset = nil }
        persistUserPresets()
    }

    private func persistUserPresets() {
        guard let data = UserPresetStore.encode(userPresets) else { return }
        UserDefaults.standard.set(data, forKey: "qsid.userPresets")
    }

    // MARK: Caméra du plateau

    struct CameraRequest: Equatable {
        enum Kind { case frame, top, front, iso }
        var kind: Kind
        var token: Int
    }

    /// Demande de vue prédéfinie, consommée par la vue du plateau (le jeton la rend rejouable).
    @Published private(set) var cameraRequest: CameraRequest?

    func requestCamera(_ kind: CameraRequest.Kind) {
        cameraRequest = CameraRequest(kind: kind, token: (cameraRequest?.token ?? 0) + 1)
    }

    // MARK: Résultat

    @Published var workspace: Workspace = .prepare
    @Published private(set) var output: SliceOutput?
    @Published private(set) var summary: SliceSummary?
    @Published private(set) var gcodeMesh: GCodeMesh?
    /// Extrudeurs (outils) réellement utilisés par le G-code, de 0 à n-1.
    @Published private(set) var usedExtruders: [Int] = []
    /// Incrémenté à chaque nouvelle géométrie d'aperçu (même nombre de couches ≠ même contenu :
    /// changement de couleur, types masqués…) ; la vue 3D se reconstruit sur ce compteur.
    @Published private(set) var gcodeMeshGeneration = 0
    /// Vrai quand la scène ou les réglages ont changé depuis le dernier slicing.
    @Published private(set) var resultIsStale = false

    @Published var colorMode: GCodeColorMode = .featureType { didSet { if colorMode != oldValue { rebuildPreview() } } }
    @Published var hiddenRoles: Set<UInt8> = [] { didSet { if hiddenRoles != oldValue { rebuildPreview() } } }
    @Published var showTravel = false { didSet { if showTravel != oldValue { rebuildPreview() } } }

    /// Incrémenté quand la langue change : l'interface est reconstruite.
    @Published var languageVersion = 0

    // MARK: Exécution

    @Published private(set) var isSlicing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText: String = ""
    @Published private(set) var statusLine: String?
    @Published var errorMessage: String?

    /// Incrémentés une fois par événement : déclenchent les retours haptiques.
    @Published private(set) var successTick = 0
    @Published private(set) var errorTick = 0

    // MARK: Imprimante (Moonraker)

    @Published var moonraker: MoonrakerConfig = MoonrakerConfig() {
        didSet { persistMoonraker() }
    }
    @Published private(set) var isUploading = false
    @Published private(set) var uploadStatus: String?
    @Published private(set) var uploadProgress: Double?
    @Published private(set) var printerStatus: PrinterStatus?
    /// Dernière erreur de lecture de l'état (réseau, adresse…), distincte du message d'envoi.
    @Published private(set) var printerError: String?

    // MARK: Réglages complets (chargés à la demande)

    @Published private(set) var settingsCatalog: SettingsCatalog?

    // MARK: Chemins

    private let locations: SlicerLocations
    private var resourcesDirectory: URL { locations.resourcesDirectory }
    private var dataDirectory: URL { locations.dataDirectory }
    private var exportsDirectory: URL { locations.exportsDirectory }
    private var workDirectory: URL { locations.workDirectory }

    private var core: SlicerCore?
    private let engineQueue = DispatchQueue(label: "qsid.engine", qos: .userInitiated)
    private var gcodeMoves: [GCodeMove] = []
    /// Chaque entrée est un groupe : un geste sur plusieurs objets s'annule en une fois.
    private var undoStack: [[TransformSnapshot]] = []
    private var redoStack: [[TransformSnapshot]] = []
    private var overridesSyncTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var isRestoring = false

    private enum DefaultsKey {
        static let printer = "qsid.printer"
        static let print = "qsid.print"
        static let filament = "qsid.filament"
        static let moonraker = "qsid.moonraker"
        static let overrides = "qsid.overrides.v2"
        static let extruders = "qsid.extruders"
    }

    // MARK: Cycle de vie

    init(locations: SlicerLocations = .bundle) {
        self.locations = locations
        restoreMoonraker()
        restoreOverrides()
        do {
            core = try SlicerCore(resourcesDirectory: resourcesDirectory, dataDirectory: dataDirectory)
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await bootstrap() }
    }

    var engineVersion: String { SlicerCore.version }

    private func bootstrap() async {
        guard core != nil else { return }
        let vendorINI = locations.vendorINI
        guard FileManager.default.fileExists(atPath: vendorINI.path) else {
            errorMessage = "Profils QIDI absents du bundle."
            return
        }
        do {
            try await onEngine { try $0.loadPresets(vendorINI: vendorINI) }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let d = UserDefaults.standard
        var printer = d.string(forKey: DefaultsKey.printer)
        if printer == nil {
            // Première utilisation : une buse 0,4 mm (la plus courante) plutôt que la
            // première de la liste triée (« … 0.2 nozzle »).
            let all = try? await onEngine { core -> [String] in
                try core.selectPresets(printer: nil, print: nil, filament: nil)
                return try core.presets(kind: "printer")
            }
            printer = all?.first(where: { $0 == "Q2 0.4 nozzle" }) ?? all?.first(where: { $0.contains("0.4") }) ?? all?.first
        }
        // Lus *avant* la première sélection : elle écrit les valeurs mémorisées.
        let storedPrint = d.string(forKey: DefaultsKey.print)
        let storedFilament = d.string(forKey: DefaultsKey.filament)
        isRestoring = true
        await applySelection(printer: printer, print: storedPrint, filament: storedFilament)
        if storedFilament == nil,
           let preferred = FilamentIndex.preferredDefault(filamentPresets), preferred != selection.filament {
            await applySelection(printer: nil, print: nil, filament: preferred)
        }
        if selection.printer.isEmpty {
            // Préset mémorisé devenu introuvable (bundle mis à jour) : on repart des défauts.
            await applySelection(printer: nil, print: nil, filament: nil)
        }
        isRestoring = false
        presetsReady = true
        await restoreExtruders()
        await refreshScene()
    }

    // MARK: Moteur (file série)

    private func onEngine<T>(_ work: @escaping (SlicerCore) throws -> T) async throws -> T {
        guard let core else { throw SlicerCoreError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            engineQueue.async {
                do { continuation.resume(returning: try work(core)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Presets

    func selectPrinter(_ name: String) {
        Task { await applySelection(printer: name, print: nil, filament: nil) }
    }

    func selectPrint(_ name: String) {
        Task { await applySelection(printer: nil, print: name, filament: nil) }
    }

    func selectFilament(_ name: String) {
        Task { await applySelection(printer: nil, print: nil, filament: name) }
    }

    private func applySelection(printer: String?, print: String?, filament: String?) async {
        do {
            // Un profil importé est abandonné dès qu'on choisit un preset.
            if !isRestoring { importedProfile = nil }
            let chosen = try await onEngine { try $0.selectPresets(printer: printer, print: print, filament: filament) }
            selection = chosen
            persistSelection()
            if isMultiFilament {
                // le moteur a réappliqué les extrudeurs : on relit les filaments retenus
                let names = extruderFilaments
                if let setup = try? await onEngine({ try $0.setExtruders(count: names.count, filaments: names) }) {
                    extruderFilaments = setup.count > 1 ? setup.filaments : []
                    persistExtruders()
                }
            }
            await refreshPresetLists()
            await syncOverrides()
            await refreshScene()
            markStale()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPresetLists() async {
        do {
            let result = try await onEngine { core in
                (try core.presets(kind: "printer"), try core.presets(kind: "print"),
                 try core.presets(kind: "filament"), try core.baseConfig())
            }
            printers = result.0
            printPresets = result.1
            filamentPresets = FilamentIndex.forPrinter(result.2, printer: selection.printer)
            baseConfig = result.3
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Libellé du profil actif pour l'interface.
    var activeProfileLabel: String {
        if let importedProfile { return importedProfile.lastPathComponent }
        let filament = selection.filament.isEmpty ? "" : " / \(selection.filament.components(separatedBy: " @").first ?? selection.filament)"
        return "\(selection.printer) · \(selection.print.components(separatedBy: " @").first ?? selection.print)\(filament)"
    }

    private func persistSelection() {
        let d = UserDefaults.standard
        d.set(selection.printer, forKey: DefaultsKey.printer)
        d.set(selection.print, forKey: DefaultsKey.print)
        d.set(selection.filament, forKey: DefaultsKey.filament)
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

    /// Ajoute un modèle à la scène (les objets déjà posés restent en place).
    func importModel(from url: URL) {
        errorMessage = nil
        Task {
            do {
                let copy = try importFile(from: url, into: dataDirectory.appendingPathComponent("models"))
                let result = try await onEngine { try $0.addToScene(copy) }
                sceneAlerts = result.alerts.isEmpty ? nil : result.alerts
                await refreshScene()
                selectedObjectID = result.added.first
                workspace = .prepare
                markStale()
            } catch {
                errorMessage = "Import du modèle impossible : \(error.localizedDescription)"
                errorTick += 1
            }
        }
    }

    /// Import par glisser-déposer (Fichiers, Shapr3D, AirDrop…).
    func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        var accepted = false
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "stl", "3mf", "obj", "amf":
                importModel(from: url); accepted = true
            case "ini":
                importProfile(from: url); accepted = true
            default:
                break
            }
        }
        return accepted
    }

    func importProfile(from url: URL) {
        errorMessage = nil
        Task {
            do {
                let copy = try importFile(from: url, into: dataDirectory.appendingPathComponent("profiles"))
                try await onEngine { try $0.loadConfigINI(copy) }
                importedProfile = copy
                await refreshPresetLists()
                await syncOverrides()
                await refreshScene()
                markStale()
            } catch {
                errorMessage = "Import du profil impossible : \(error.localizedDescription)"
            }
        }
    }

    func clearProfile() {
        Task { await applySelection(printer: selection.printer, print: selection.print, filament: selection.filament) }
    }

    // MARK: Réglages

    private func restoreOverrides() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.overrides),
              let saved = try? JSONDecoder().decode(SliceOverrides.self, from: data) else { return }
        overrides = saved
    }

    private func persistOverrides() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.overrides)
    }

    private func scheduleOverridesSync() {
        overridesSyncTask?.cancel()
        overridesSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)   // regroupe les changements rapides (curseurs)
            guard !Task.isCancelled else { return }
            await self?.syncOverrides()
            self?.markStale()
        }
    }

    /// Pousse les réglages de l'utilisateur dans le moteur (qui les valide).
    private func syncOverrides() async {
        guard core != nil, presetsReady || isRestoring || !baseConfig.isEmpty else { return }
        let entries = overrides.configEntries(basedOn: baseConfig)
        do {
            let rejected = try await onEngine { core -> [String] in
                core.resetConfig()
                var bad: [String] = []
                for (key, value) in entries {
                    do { try core.setConfig(key, value) } catch { bad.append(key) }
                }
                return bad
            }
            if !rejected.isEmpty {
                for key in rejected { overrides.reset(key) }
                errorMessage = "Réglage(s) refusé(s) par le moteur : \(rejected.sorted().joined(separator: ", "))"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Valeur effective (réglage forcé, sinon preset) d'une option.
    func value(of key: String) -> String? { overrides.value(key, base: baseConfig) }

    func setOption(_ key: String, _ value: String) { overrides.set(key, value, base: baseConfig) }
    func resetOption(_ key: String) { overrides.reset(key) }

    /// À appeler quand la langue change : le catalogue des réglages suit.
    func refreshLanguage() { settingsCatalog?.useFrench = !L10n.isEnglish }

    /// Charge (une fois) le schéma des options, la disposition des onglets et les traductions.
    func loadSettingsCatalog() async {
        guard settingsCatalog == nil, core != nil else { return }
        do {
            let schema = try await onEngine { try $0.configSchemaJSON() }
            guard let pagesURL = locations.configPagesURL,
                  let pages = try? Data(contentsOf: pagesURL) else {
                errorMessage = "Ressource des réglages absente."
                return
            }
            let french = locations.configFrenchURL.flatMap { try? Data(contentsOf: $0) }
            settingsCatalog = try SettingsCatalog(schemaJSON: schema, layoutJSON: pages, frenchJSON: french,
                                                  useFrench: !L10n.isEnglish)
        } catch {
            errorMessage = "Réglages complets indisponibles : \(error.localizedDescription)"
        }
    }

    // MARK: Scène

    private func refreshScene() async {
        do {
            let info = try await onEngine { try $0.sceneInfo() }
            let missing = info.objects.map(\.id).filter { meshes[$0] == nil }
            if !missing.isEmpty {
                let loaded = try await onEngine { core -> [(UInt64, [Float])] in
                    missing.map { ($0, (try? core.sceneMesh(objectID: $0)) ?? []) }
                }
                for (id, triangles) in loaded { meshes[id] = triangles }
            }
            let live = Set(info.objects.map(\.id))
            for id in meshes.keys where !live.contains(id) { meshes[id] = nil }
            scene = info
            let kept = selectedObjectIDs.intersection(live)
            if kept != selectedObjectIDs { selectedObjectIDs = kept }
            if let selected = primaryObjectID, !live.contains(selected) { primaryObjectID = kept.first }
            if let plane = cutPlane, !live.contains(plane.objectID) { cutPlane = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissAlerts() { sceneAlerts = nil }

    var selectedObject: SceneObject? {
        guard let id = selectedObjectID else { return nil }
        return scene?.objects.first { $0.id == id }
    }

    /// Tous les objets sélectionnés, dans l'ordre de la scène.
    var selectedObjects: [SceneObject] {
        scene?.objects.filter { selectedObjectIDs.contains($0.id) } ?? []
    }

    var hasMultipleSelected: Bool { selectedObjectIDs.count > 1 }

    // MARK: Sélection multiple

    func isSelected(_ id: UInt64) -> Bool { selectedObjectIDs.contains(id) }

    /// Ajoute l'objet à la sélection, ou l'en retire s'il y est déjà (toucher avec « Ajouter »).
    func toggleSelection(_ id: UInt64) {
        guard scene?.objects.contains(where: { $0.id == id }) == true else { return }
        if selectedObjectIDs.contains(id) {
            selectedObjectIDs.remove(id)
            if primaryObjectID == id { primaryObjectID = selectedObjectIDs.first }
        } else {
            selectedObjectIDs.insert(id)
            primaryObjectID = id
        }
    }

    /// ⌘A : tous les objets du plateau.
    func selectAll() {
        guard let objects = scene?.objects, !objects.isEmpty else { return }
        selectedObjectIDs = Set(objects.map(\.id))
        if primaryObjectID == nil || !selectedObjectIDs.contains(primaryObjectID!) { primaryObjectID = objects.first?.id }
    }

    func clearSelection() { selectedObjectID = nil }

    private func snapshot(of object: SceneObject, instance: Int = 0) -> TransformSnapshot? {
        guard instance < object.instances.count else { return nil }
        let i = object.instances[instance]
        return TransformSnapshot(objectID: object.id, instance: instance,
                                 offset: i.offset, rotationDeg: i.rotationDeg, scale: i.scale)
    }

    /// Applique une transformation (geste terminé ou saisie dans l'inspecteur).
    func transform(objectID: UInt64, instance: Int = 0,
                   offset: [Double]? = nil, rotationDeg: [Double]? = nil, scale: [Double]? = nil,
                   dropToBed: Bool = false, recordUndo: Bool = true) {
        applyTransforms([TransformChange(objectID: objectID, instance: instance, offset: offset,
                                         rotationDeg: rotationDeg, scale: scale, dropToBed: dropToBed)],
                        recordUndo: recordUndo)
    }

    /// Applique plusieurs transformations d'un coup (un seul pas d'annulation).
    func applyTransforms(_ changes: [TransformChange], recordUndo: Bool = true) {
        guard let objects = scene?.objects else { return }
        let before = changes.compactMap { change in
            objects.first(where: { $0.id == change.objectID }).flatMap { snapshot(of: $0, instance: change.instance) }
        }
        guard !before.isEmpty else { return }
        Task {
            do {
                try await onEngine { core in
                    for c in changes {
                        try core.setTransform(objectID: c.objectID, instance: c.instance, offset: c.offset,
                                              rotationDeg: c.rotationDeg, scale: c.scale, dropToBed: c.dropToBed)
                    }
                }
                if recordUndo {
                    undoStack.append(before)
                    if undoStack.count > 100 { undoStack.removeFirst() }
                    redoStack.removeAll()
                    updateUndoFlags()
                }
                await refreshScene()
                markStale()
            } catch {
                errorMessage = error.localizedDescription
                await refreshScene()   // la vue revient à l'état réel du moteur
            }
        }
    }

    func undo() {
        guard let group = undoStack.popLast() else { updateUndoFlags(); return }
        redoStack.append(group.compactMap(currentSnapshot(matching:)))
        restore(group)
    }

    func redo() {
        guard let group = redoStack.popLast() else { updateUndoFlags(); return }
        undoStack.append(group.compactMap(currentSnapshot(matching:)))
        restore(group)
    }

    /// État actuel de l'instance visée par `snap` (pour pouvoir y revenir : rétablir / annuler).
    /// Pas d'`inout` croisé entre les deux piles : l'exclusivité d'accès de Swift l'interdit.
    private func currentSnapshot(matching snap: TransformSnapshot) -> TransformSnapshot? {
        guard let object = scene?.objects.first(where: { $0.id == snap.objectID }) else { return nil }
        return snapshot(of: object, instance: snap.instance)
    }

    private func restore(_ group: [TransformSnapshot]) {
        updateUndoFlags()
        applyTransforms(group.map {
            TransformChange(objectID: $0.objectID, instance: $0.instance, offset: $0.offset,
                            rotationDeg: $0.rotationDeg, scale: $0.scale)
        }, recordUndo: false)
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Déplacement d'un pas (flèches du clavier ; ⇧ = 10 mm), borné au plateau. Le groupe
    /// sélectionné bouge d'un bloc.
    func nudgeSelected(dx: Double, dy: Double) {
        let objects = selectedObjects
        guard !objects.isEmpty, let bed = scene?.bed else { return }
        let shift = SelectionGroup.clampedShift(of: objects, dx: dx, dy: dy, bed: bed)
        applyTransforms(objects.compactMap { object in
            object.instances.first.map { inst in
                TransformChange(objectID: object.id,
                                offset: [inst.offset[0] + shift.x, inst.offset[1] + shift.y, inst.offset[2]])
            }
        })
    }

    /// Déplace tout le groupe sélectionné de (dx, dy) (glisser d'un objet de la sélection).
    func moveSelection(dx: Double, dy: Double) { nudgeSelected(dx: dx, dy: dy) }

    func duplicateSelected() {
        let objects = selectedObjects
        guard !objects.isEmpty else { return }
        let counts = objects.map { ($0.id, $0.instances.count + 1) }
        mutateScene { core in for (id, count) in counts { try core.setInstanceCount(objectID: id, count: count) } }
    }

    func deleteSelected() {
        let ids = Array(selectedObjectIDs)
        guard !ids.isEmpty else { return }
        mutateScene { core in for id in ids { try core.removeObject(id) } }
        selectedObjectID = nil
    }

    /// Pose tous les objets sélectionnés sur le plateau.
    func dropSelectedToBed() {
        let ids = Array(selectedObjectIDs)
        mutateScene { core in for id in ids { try core.dropToBed(objectID: id) } }
    }

    /// Remet la rotation d'origine de tous les objets sélectionnés.
    func resetRotationOfSelection() {
        applyTransforms(selectedObjects.map { TransformChange(objectID: $0.id, rotationDeg: [0, 0, 0], dropToBed: true) })
    }

    func setInstanceCount(_ count: Int, objectID: UInt64) {
        mutateScene { try $0.setInstanceCount(objectID: objectID, count: count) }
    }

    func arrange() { mutateScene { try $0.arrangeScene() } }

    func dropToBed(_ id: UInt64) { mutateScene { try $0.dropToBed(objectID: id) } }

    /// Remet l'orientation d'origine (rotation nulle), l'objet restant posé sur le plateau.
    func resetRotation(_ id: UInt64) { transform(objectID: id, rotationDeg: [0, 0, 0], dropToBed: true) }

    /// Conversion d'unités (pouces → mm : 25,4 ; mètres → mm : 1000).
    func scaleSelected(by factor: Double) {
        applyTransforms(selectedObjects.compactMap { object in
            object.instances.first.map { TransformChange(objectID: object.id, scale: $0.scale.map { $0 * factor }, dropToBed: true) }
        })
    }

    // MARK: Coupe

    /// Ouvre l'outil de coupe sur l'objet sélectionné (plan horizontal au milieu).
    func beginCut(axis: CutPlane.Axis = .z) {
        guard let object = selectedObject, let plane = CutPlane.centered(on: object, axis: axis) else {
            errorMessage = L10n.t("Cet objet est trop petit pour être coupé.")
            return
        }
        cutPlane = plane
    }

    func cancelCut() { cutPlane = nil }

    /// Change l'axe du plan en gardant le milieu de l'objet.
    func setCutAxis(_ axis: CutPlane.Axis) {
        guard let plane = cutPlane, plane.axis != axis,
              let object = scene?.objects.first(where: { $0.id == plane.objectID }),
              let moved = CutPlane.centered(on: object, axis: axis) else { return }
        cutPlane = moved
    }

    /// Coupe l'objet au plan courant. Les deux moitiés (ou celle gardée) sont sélectionnées.
    func applyCut(keep: CutPlane.Keep, placeOnCut: Bool) {
        guard let plane = cutPlane,
              let object = scene?.objects.first(where: { $0.id == plane.objectID }),
              let inst = object.instances.first, plane.isValid(for: inst) else {
            errorMessage = L10n.t("Le plan de coupe doit traverser l'objet.")
            return
        }
        let point = plane.point(in: inst), normal = plane.axis.normal
        let id = object.id
        cutPlane = nil
        Task {
            do {
                let result = try await onEngine {
                    try $0.cut(objectID: id, point: point, normal: normal, keep: keep.rawValue, placeOnCut: placeOnCut)
                }
                await refreshScene()
                selectedObjectIDs = Set(result.objects)
                primaryObjectID = result.objects.first
                statusLine = String(format: L10n.t("Coupe faite : %ld objet(s)."), result.objects.count)
                markStale()
            } catch {
                errorMessage = L10n.t("Coupe impossible : ") + error.localizedDescription
                errorTick += 1
                await refreshScene()
            }
        }
    }

    // MARK: Simplification

    /// Réduit le nombre de triangles de l'objet à `ratio` (0..1) du total.
    func simplify(objectID: UInt64, ratio: Double) {
        Task {
            do {
                let result = try await onEngine { try $0.simplify(objectID: objectID, ratio: ratio) }
                meshes[objectID] = nil   // le maillage a changé : rechargé par refreshScene
                await refreshScene()
                statusLine = String(format: L10n.t("Maillage simplifié : %ld → %ld triangles."), result.before, result.after)
                markStale()
            } catch {
                errorMessage = L10n.t("Simplification impossible : ") + error.localizedDescription
                errorTick += 1
            }
        }
    }

    // MARK: Réglages par objet, modificateurs, plages de couches

    /// Valeur d'une option pour un objet (réglage propre, sinon valeur globale effective).
    func objectValue(of key: String, objectID: UInt64, volumeID: UInt64 = 0) -> String? {
        guard let object = scene?.objects.first(where: { $0.id == objectID }) else { return nil }
        let own = volumeID == 0 ? object.config[key] : object.volumes.first(where: { $0.id == volumeID })?.config[key]
        return own ?? (volumeID == 0 ? nil : object.config[key]) ?? value(of: key)
    }

    func isObjectOptionModified(_ key: String, objectID: UInt64, volumeID: UInt64 = 0) -> Bool {
        guard let object = scene?.objects.first(where: { $0.id == objectID }) else { return false }
        return (volumeID == 0 ? object.config : object.volumes.first(where: { $0.id == volumeID })?.config ?? [:])[key] != nil
    }

    func setObjectOption(_ key: String, _ value: String, objectID: UInt64, volumeID: UInt64 = 0) {
        mutateScene { try $0.setObjectConfig(objectID: objectID, volumeID: volumeID, key: key, value: value) }
    }

    func resetObjectOption(_ key: String?, objectID: UInt64, volumeID: UInt64 = 0) {
        mutateScene { try $0.resetObjectConfig(objectID: objectID, volumeID: volumeID, key: key) }
    }

    func addModifier(objectID: UInt64, shape: ObjectSettings.ModifierShape, kind: ObjectSettings.ModifierKind) {
        guard let inst = scene?.objects.first(where: { $0.id == objectID })?.instances.first else { return }
        let start = ObjectSettings.defaultModifier(for: inst)
        mutateScene {
            try $0.addModifier(objectID: objectID, shape: shape.rawValue, kind: kind.rawValue,
                               centerWorld: start.center, size: start.size)
        }
    }

    func updateModifier(objectID: UInt64, volumeID: UInt64, centerWorld: [Double]?, size: [Double]?) {
        mutateScene { try $0.setModifier(objectID: objectID, volumeID: volumeID, centerWorld: centerWorld, size: size) }
    }

    func removeModifier(objectID: UInt64, volumeID: UInt64) {
        mutateScene { try $0.removeVolume(objectID: objectID, volumeID: volumeID) }
    }

    func addLayerRange(objectID: UInt64) {
        guard let object = scene?.objects.first(where: { $0.id == objectID }),
              let range = ObjectSettings.defaultLayerRange(for: object) else {
            errorMessage = L10n.t("Plus de place pour une plage de hauteurs.")
            return
        }
        let layerHeight = value(of: "layer_height")
        mutateScene { try $0.setLayerRange(objectID: objectID, minZ: range.min, maxZ: range.max,
                                           key: "layer_height", value: layerHeight) }
    }

    func setLayerRangeOption(objectID: UInt64, minZ: Double, maxZ: Double, key: String, value: String) {
        mutateScene { try $0.setLayerRange(objectID: objectID, minZ: minZ, maxZ: maxZ, key: key, value: value) }
    }

    /// Change les bornes d'une plage en gardant ses réglages ; l'ancienne plage est rétablie si le moteur refuse.
    func moveLayerRange(objectID: UInt64, from: SceneLayerRange, minZ: Double, maxZ: Double) {
        let entries = from.config.sorted { $0.key < $1.key }
        mutateScene { core in
            try core.removeLayerRange(objectID: objectID, minZ: from.min, maxZ: from.max)
            do {
                try core.setLayerRange(objectID: objectID, minZ: minZ, maxZ: maxZ)
                for (key, value) in entries {
                    try core.setLayerRange(objectID: objectID, minZ: minZ, maxZ: maxZ, key: key, value: value)
                }
            } catch {
                try? core.setLayerRange(objectID: objectID, minZ: from.min, maxZ: from.max)
                for (key, value) in entries {
                    try? core.setLayerRange(objectID: objectID, minZ: from.min, maxZ: from.max, key: key, value: value)
                }
                throw error
            }
        }
    }

    func removeLayerRange(objectID: UInt64, minZ: Double, maxZ: Double, key: String? = nil) {
        mutateScene { try $0.removeLayerRange(objectID: objectID, minZ: minZ, maxZ: maxZ, key: key) }
    }

    func layOnFace(objectID: UInt64, triangle: Int) {
        layOnFaceMode = false
        mutateScene { try $0.layOnFace(objectID: objectID, triangle: triangle) }
    }

    func clearScene() {
        mutateScene { try $0.clearScene() }
        selectedObjectID = nil
        meshes.removeAll()
        output = nil; summary = nil; gcodeMesh = nil; gcodeMoves = []; usedExtruders = []
        gcodeMeshGeneration += 1
    }

    private func mutateScene(_ work: @escaping (SlicerCore) throws -> Void) {
        Task {
            do {
                try await onEngine(work)
                await refreshScene()
                markStale()
            } catch {
                errorMessage = error.localizedDescription
                errorTick += 1
            }
        }
    }

    private func markStale() {
        if output != nil { resultIsStale = true }
    }

    // MARK: Slicing

    var canSlice: Bool { !(scene?.objects.isEmpty ?? true) && !isSlicing && presetsReady }

    private var outputName: String {
        let base = scene?.objects.first.map { ($0.name as NSString).deletingPathExtension } ?? "plateau"
        let safe = base.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" }
        return String(safe).trimmingCharacters(in: .whitespaces).isEmpty ? "plateau" : String(safe)
    }

    func slice() {
        guard canSlice else {
            if scene?.objects.isEmpty ?? true { errorMessage = "Importez d'abord un modèle (STL, 3MF, OBJ)." }
            return
        }
        if scene?.hasObjectOutsideBed == true {
            errorMessage = "Un objet sort du plateau : déplacez-le ou touchez « Organiser »."
            errorTick += 1
            return
        }

        let outputURL = exportsDirectory.appendingPathComponent(outputName).appendingPathExtension("gcode")
        isSlicing = true
        progress = 0
        progressText = "Préparation…"
        statusLine = nil
        errorMessage = nil
        let started = Date()
        // Les callbacks arrivent du thread de slicing, plusieurs fois par seconde : on
        // ne garde que la dernière valeur et on l'applique à cadence fixe.
        let relay = ProgressRelay { [weak self] percent, text in
            guard let self, self.isSlicing else { return }
            if percent >= 0 { self.progress = Double(percent) / 100.0 }
            if !text.isEmpty { self.progressText = text }
        }

        // Vignettes de l'aperçu de l'imprimante : rendues depuis la scène telle qu'elle est.
        let thumbnails = makeThumbnailProvider()

        Task {
            defer { relay.stop() }
            // Les réglages modifiés à l'instant doivent être dans le moteur avant de slicer.
            await overridesSyncTask?.value
            // Un slicing dure de quelques secondes à quelques minutes : écran éveillé et
            // temps d'exécution en arrière-plan (iOS suspend sinon l'app en fond).
            let keepAwake = KeepAwake()
            defer { keepAwake.end() }
            do {
                let result = try await onEngine { core -> (SliceSummary, [GCodeMove]) in
                    core.setThumbnailProvider(thumbnails)
                    let summary = try core.sliceScene(output: outputURL) { percent, text in
                        relay.push(percent: Int(percent), text: text)
                    }
                    let moves = try core.gcodeMoves().map(GCodeMove.init)
                    core.releaseResult()   // les mouvements sont chez nous : le moteur les libère
                    return (summary, moves)
                }
                relay.stop()
                let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
                summary = result.0
                gcodeMoves = result.1
                usedExtruders = Set(result.1.lazy.filter { $0.moveType == .extrude }.map { Int($0.extruder) }).sorted()
                output = SliceOutput(url: outputURL, sizeBytes: (attrs?[.size] as? Int64) ?? 0,
                                     seconds: Date().timeIntervalSince(started))
                resultIsStale = false
                progress = 1
                progressText = "Terminé"
                statusLine = "Terminé en \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
                if let warning = result.0.warnings.first { errorMessage = warning }
                rebuildPreview()
                workspace = .preview
                successTick += 1
            } catch SlicerCoreError.canceled {
                errorTick += 1
                statusLine = L10n.t("Slicing annulé.")
                progress = 0
                progressText = ""
            } catch {
                errorMessage = error.localizedDescription
                statusLine = nil
                errorTick += 1
            }
            isSlicing = false
        }
    }

    func cancel() { core?.cancel() }

    private func makeThumbnailProvider() -> ThumbnailProvider? {
        guard let objects = scene?.objects, !objects.isEmpty else { return nil }
        var lo = Vec3(repeating: .greatestFiniteMagnitude), hi = Vec3(repeating: -.greatestFiniteMagnitude)
        var items: [ThumbnailProvider.Item] = []
        for object in objects {
            guard let triangles = meshes[object.id], !triangles.isEmpty else { continue }
            items.append(.init(triangles: triangles, matrices: object.instances.map { BedSceneCoordinator.simdMatrix($0.matrix) }))
            for i in object.instances {
                lo = Vec3(Swift.min(lo.x, i.min[0]), Swift.min(lo.y, i.min[1]), Swift.min(lo.z, i.min[2]))
                hi = Vec3(Swift.max(hi.x, i.max[0]), Swift.max(hi.y, i.max[1]), Swift.max(hi.z, i.max[2]))
            }
        }
        return items.isEmpty ? nil : ThumbnailProvider(items: items, boundsMin: lo, boundsMax: hi)
    }

    // MARK: Aperçu

    /// Reconstruit la géométrie de l'aperçu (hors du thread principal).
    private func rebuildPreview() {
        guard !gcodeMoves.isEmpty else { gcodeMesh = nil; gcodeMeshGeneration += 1; return }
        rebuildTask?.cancel()
        var builder = GCodeMeshBuilder()
        builder.mode = colorMode
        builder.hiddenRoles = hiddenRoles
        builder.includeTravel = showTravel
        builder.toolColors = GCodeMeshBuilder.parseColors(value(of: "filament_colour") ?? "")
        let moves = gcodeMoves
        let configured = builder   // copie immuable : capturée par la tâche détachée
        rebuildTask = Task {
            let mesh = await Task.detached(priority: .userInitiated) { configured.build(moves: moves) }.value
            guard !Task.isCancelled else { return }
            gcodeMesh = mesh
            gcodeMeshGeneration += 1
        }
    }

    // MARK: Envoi à l'imprimante

    private func restoreMoonraker() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.moonraker),
              let config = try? JSONDecoder().decode(MoonrakerConfig.self, from: data) else { return }
        moonraker = config
    }

    private func persistMoonraker() {
        guard let data = try? JSONEncoder().encode(moonraker) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.moonraker)
    }

    func uploadAndPrint() {
        guard let output else { return }
        guard moonraker.isConfigured else {
            errorMessage = MoonrakerError.notConfigured.localizedDescription
            return
        }
        isUploading = true
        uploadStatus = "Envoi…"
        uploadProgress = 0
        errorMessage = nil

        let client = MoonrakerClient(config: moonraker)
        let file = output.url
        Task {
            do {
                try await client.upload(file: file, filename: file.lastPathComponent) { [weak self] fraction in
                    Task { @MainActor in self?.uploadProgress = fraction }
                }
                self.uploadStatus = "Envoi terminé, démarrage…"
                if self.useBox {
                    // même préparation que QIDISlicer desktop : activer le Box et associer les outils aux emplacements
                    let tools = (0..<self.extruderCount).map { $0 < self.boxSlots.count ? self.boxSlots[$0] : $0 }
                    for command in QIDIBox.activationCommands(slots: tools, enabled: true) {
                        try await client.sendGCode(command)
                    }
                }
                try await client.startPrint(filename: file.lastPathComponent)
                self.uploadStatus = "Impression lancée."
                self.refreshPrinterStatus()
            } catch {
                self.uploadStatus = nil
                self.errorMessage = error.localizedDescription
            }
            self.uploadProgress = nil
            self.isUploading = false
        }
    }

    // MARK: Multi-filament et QIDI Box

    /// Filament de chaque extrudeur ; vide = impression mono-filament.
    @Published private(set) var extruderFilaments: [String] = []
    /// Associer chaque extrudeur à un emplacement du QIDI Box avant de lancer l'impression.
    @Published var useBox = UserDefaults.standard.bool(forKey: "qsid.box.use") {
        didSet { UserDefaults.standard.set(useBox, forKey: "qsid.box.use") }
    }
    /// Emplacement du Box (0…15 = 1A…4D) de chaque extrudeur.
    @Published var boxSlots: [Int] = (UserDefaults.standard.array(forKey: "qsid.box.slots") as? [Int]) ?? [] {
        didSet { UserDefaults.standard.set(boxSlots, forKey: "qsid.box.slots") }
    }
    @Published private(set) var boxStatus: String?

    var extruderCount: Int { max(extruderFilaments.count, 1) }
    var isMultiFilament: Bool { extruderFilaments.count > 1 }

    /// Couleurs des filaments (#RRGGBB), une par extrudeur, d'après la configuration effective.
    var filamentColors: [String] {
        let raw = value(of: "filament_colour") ?? ""
        var colors = raw.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        while colors.count < extruderCount { colors.append(colors.last ?? "#3399FF") }
        return Array(colors.prefix(extruderCount))
    }

    /// Fixe le nombre d'extrudeurs (1 à 16) en gardant les filaments déjà choisis.
    func setExtruderCount(_ count: Int) {
        let n = min(max(count, 1), QIDIBox.slotCount)
        var names = isMultiFilament ? extruderFilaments : [selection.filament]
        while names.count < n { names.append(names.last ?? selection.filament) }
        applyExtruders(Array(names.prefix(n)))
    }

    func setExtruderFilament(_ index: Int, _ name: String) {
        var names = isMultiFilament ? extruderFilaments : [selection.filament]
        guard index >= 0, index < names.count else { return }
        names[index] = name
        applyExtruders(names)
    }

    /// Couleur d'un filament (remplace `filament_colour` pour cet extrudeur).
    func setFilamentColor(_ index: Int, hex: String) {
        var colors = filamentColors
        guard index >= 0, index < colors.count else { return }
        colors[index] = hex
        overrides.set("filament_colour", colors.joined(separator: ";"), base: baseConfig)
    }

    private func applyExtruders(_ names: [String]) {
        Task { await applyExtrudersNow(names) }
    }

    private func applyExtrudersNow(_ names: [String]) async {
        do {
            await overridesSyncTask?.value
            let setup = try await onEngine { try $0.setExtruders(count: names.count, filaments: names) }
            extruderFilaments = setup.count > 1 ? setup.filaments : []
            if extruderFilaments.isEmpty { overrides.reset("filament_colour") }
            while boxSlots.count < setup.count { boxSlots.append(QIDIBox.defaultSlots(count: setup.count)[boxSlots.count]) }
            persistExtruders()
            await refreshPresetLists()
            await syncOverrides()
            await refreshScene()
            markStale()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistExtruders() {
        if let data = try? JSONEncoder().encode(extruderFilaments) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.extruders)
        }
    }

    private func restoreExtruders() async {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.extruders),
              let saved = try? JSONDecoder().decode([String].self, from: data), saved.count > 1 else { return }
        await applyExtrudersNow(saved)
    }

    /// Lit l'association outil → emplacement enregistrée dans l'imprimante (variables Klipper).
    func readBoxFromPrinter() {
        guard moonraker.isConfigured else { errorMessage = MoonrakerError.notConfigured.localizedDescription; return }
        let client = MoonrakerClient(config: moonraker)
        boxStatus = L10n.t("Lecture du Box…")
        Task {
            do {
                guard let variables = try await client.boxVariables() else {
                    boxStatus = L10n.t("Aucune information de Box dans l'imprimante.")
                    return
                }
                useBox = variables.enabled
                var slots = boxSlots
                for tool in 0..<min(slots.count, variables.slots.count) {
                    if let slot = variables.slots[tool] { slots[tool] = slot }
                }
                boxSlots = slots
                boxStatus = variables.enabled ? L10n.t("Box activé dans l'imprimante.") : L10n.t("Box désactivé dans l'imprimante.")
            } catch {
                boxStatus = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Découverte des imprimantes

    @Published private(set) var discoveredPrinters: [DiscoveredPrinter] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var discoveryProgress = 0.0
    /// Recherche Bonjour (fournie par l'app : Network.framework n'existe pas partout) : adresses IPv4 annoncées.
    var bonjourHosts: ((TimeInterval) async -> [String])?
    private var discoveryTask: Task<Void, Never>?

    /// Cherche les imprimantes Moonraker du réseau local : Bonjour d'abord (rapide), puis
    /// balayage des sous-réseaux. `hosts` remplace la liste d'adresses (tests).
    func startDiscovery(hosts: [String]? = nil, port: Int = 7125) {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryProgress = 0
        discoveredPrinters = []
        printerError = nil
        let bonjour = bonjourHosts
        discoveryTask = Task { [weak self] in
            var candidates = hosts ?? []
            if hosts == nil {
                let announced = await bonjour?(2.5) ?? []
                candidates = announced
                let seen = Set(announced)
                candidates += PrinterDiscovery.allCandidateHosts().filter { !seen.contains($0) }
            }
            let found = await PrinterDiscovery.scan(hosts: candidates, port: port) { done, total in
                Task { @MainActor [weak self] in self?.discoveryProgress = total == 0 ? 1 : Double(done) / Double(total) }
            }
            guard let self else { return }
            self.discoveredPrinters = found
            self.discoveryProgress = 1
            self.isDiscovering = false
        }
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscovering = false
    }

    /// Reprend l'adresse d'une imprimante trouvée et teste la connexion.
    func usePrinter(_ printer: DiscoveredPrinter) {
        moonraker.host = printer.host
        moonraker.port = printer.port
        refreshPrinterStatus()
    }

    func refreshPrinterStatus() {
        guard moonraker.isConfigured else { return }
        let client = MoonrakerClient(config: moonraker)
        Task {
            do {
                printerStatus = try await client.status()
                printerError = nil
            } catch {
                printerStatus = nil
                printerError = error.localizedDescription
            }
        }
    }
}

// MARK: - Aides

/// Écran éveillé + tâche d'arrière-plan pendant un calcul long.
@MainActor
final class KeepAwake {
    private var task: UIBackgroundTaskIdentifier = .invalid

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        task = UIApplication.shared.beginBackgroundTask(withName: "qsid.slice") { [weak self] in
            self?.end()
        }
    }

    func end() {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// Relais de progression : thread de slicing → thread principal, valeur la plus
/// récente seulement, ~10 Hz.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (percent: Int, text: String)?
    private var timer: DispatchSourceTimer?
    private let apply: @MainActor (Int, String) -> Void

    init(apply: @escaping @MainActor (Int, String) -> Void) {
        self.apply = apply
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    func push(percent: Int, text: String) {
        lock.lock(); latest = (percent, text); lock.unlock()
    }

    private func flush() {
        lock.lock(); let value = latest; latest = nil; lock.unlock()
        guard let value else { return }
        MainActor.assumeIsolated { apply(value.percent, value.text) }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
