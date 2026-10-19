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
    @Published var selectedObjectID: UInt64?
    /// Triangles locaux (9 floats chacun) par objet.
    @Published private(set) var meshes: [UInt64: [Float]] = [:]
    @Published private(set) var sceneAlerts: SceneAlerts?
    /// Mode « poser sur une face » : le prochain toucher choisit la face.
    @Published var layOnFaceMode = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // MARK: Calibration

    @Published private(set) var calibration: CalibrationKind?
    private var overridesBeforeCalibration: SliceOverrides?

    /// Prépare une impression de calibration : vide le plateau, charge le modèle fourni,
    /// applique les réglages temporaires. `endCalibration()` restaure tout.
    func startCalibration(_ kind: CalibrationKind) {
        errorMessage = nil
        let height = Double(baseConfig["max_print_height"] ?? "") ?? 250
        let plan: CalibrationPlan
        do {
            let effective = Dictionary(uniqueKeysWithValues: ["start_gcode", "before_layer_gcode"].map { ($0, value(of: $0) ?? "") })
            plan = try Calibration.plan(for: kind, base: effective, maxPrintHeight: height)
        } catch {
            errorMessage = "Calibration impossible : \(error)"
            return
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("qidi/calib/\(plan.resource)"),
              FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Modèle de calibration absent du bundle."
            return
        }
        Task {
            do {
                try await onEngine { try $0.clearScene() }
                meshes.removeAll()
                if overridesBeforeCalibration == nil { overridesBeforeCalibration = overrides }
                for (key, value) in plan.overrides { overrides.set(key, value, base: baseConfig) }
                let added = try await onEngine { try $0.addToScene(url) }
                await refreshScene()
                if let target = plan.targetHeight,
                   let id = added.added.first,
                   let object = scene?.objects.first(where: { $0.id == id }),
                   object.localSize[2] > 1e-6 {
                    transform(objectID: id, scale: [1, 1, target / object.localSize[2]], dropToBed: true, recordUndo: false)
                }
                calibration = kind
                selectedObjectID = nil
                output = nil; summary = nil; gcodeMesh = nil; gcodeMoves = []
                workspace = .prepare
                requestCamera(.frame)
            } catch {
                errorMessage = "Calibration impossible : \(error.localizedDescription)"
            }
        }
    }

    /// Quitte la calibration : réglages d'origine restaurés, plateau vidé.
    func endCalibration() {
        if let saved = overridesBeforeCalibration { overrides = saved }
        overridesBeforeCalibration = nil
        calibration = nil
        clearScene()
    }

    // MARK: Export de la configuration

    @Published private(set) var exportedConfigURL: URL?

    /// Écrit la configuration effective (preset + réglages) en .ini, réimportable dans QIDISlicer
    /// desktop ou dans cette app (« Importer un profil »).
    func prepareConfigExport() {
        Task {
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

    // MARK: Préréglages utilisateur (jeux de réglages nommés)

    @Published private(set) var userPresets: [String: SliceOverrides] = {
        guard let data = UserDefaults.standard.data(forKey: "qsid.userPresets"),
              let saved = try? JSONDecoder().decode([String: SliceOverrides].self, from: data) else { return [:] }
        return saved
    }()

    /// Enregistre les réglages actuels sous `name` (remplace un préréglage du même nom).
    func saveUserPreset(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !overrides.isEmpty else { return }
        userPresets[clean] = overrides
        persistUserPresets()
    }

    func applyUserPreset(_ name: String) {
        if let preset = userPresets[name] { overrides = preset }
    }

    func deleteUserPreset(_ name: String) {
        userPresets[name] = nil
        persistUserPresets()
    }

    private func persistUserPresets() {
        guard let data = try? JSONEncoder().encode(userPresets) else { return }
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

    // MARK: Réglages complets (chargés à la demande)

    @Published private(set) var settingsCatalog: SettingsCatalog?

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
    private let engineQueue = DispatchQueue(label: "qsid.engine", qos: .userInitiated)
    private var gcodeMoves: [GCodeMove] = []
    private var undoStack: [TransformSnapshot] = []
    private var redoStack: [TransformSnapshot] = []
    private var overridesSyncTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var isRestoring = false

    private enum DefaultsKey {
        static let printer = "qsid.printer"
        static let print = "qsid.print"
        static let filament = "qsid.filament"
        static let moonraker = "qsid.moonraker"
        static let overrides = "qsid.overrides.v2"
    }

    // MARK: Cycle de vie

    init() {
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

    private var vendorINI: URL? {
        Bundle.main.url(forResource: "QIDITechnology", withExtension: "ini", subdirectory: "qidi/profiles")
    }

    private func bootstrap() async {
        guard core != nil else { return }
        guard let vendorINI else {
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
            printer = all?.first(where: { $0.contains("0.4") }) ?? all?.first
        }
        isRestoring = true
        await applySelection(printer: printer,
                             print: d.string(forKey: DefaultsKey.print),
                             filament: d.string(forKey: DefaultsKey.filament))
        if d.string(forKey: DefaultsKey.filament) == nil,
           let preferred = FilamentIndex.preferredDefault(filamentPresets), preferred != selection.filament {
            await applySelection(printer: nil, print: nil, filament: preferred)
        }
        if selection.printer.isEmpty {
            // Préset mémorisé devenu introuvable (bundle mis à jour) : on repart des défauts.
            await applySelection(printer: nil, print: nil, filament: nil)
        }
        isRestoring = false
        presetsReady = true
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
            guard let pagesURL = Bundle.main.url(forResource: "config_pages", withExtension: "json"),
                  let pages = try? Data(contentsOf: pagesURL) else {
                errorMessage = "Ressource des réglages absente."
                return
            }
            let french = Bundle.main.url(forResource: "config_fr", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
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
            if let selected = selectedObjectID, !live.contains(selected) { selectedObjectID = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissAlerts() { sceneAlerts = nil }

    var selectedObject: SceneObject? {
        guard let id = selectedObjectID else { return nil }
        return scene?.objects.first { $0.id == id }
    }

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
        guard let object = scene?.objects.first(where: { $0.id == objectID }) else { return }
        let before = snapshot(of: object, instance: instance)
        Task {
            do {
                try await onEngine {
                    try $0.setTransform(objectID: objectID, instance: instance, offset: offset,
                                        rotationDeg: rotationDeg, scale: scale, dropToBed: dropToBed)
                }
                if recordUndo, let before {
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

    func undo() { stepHistory(from: &undoStack, to: &redoStack) }
    func redo() { stepHistory(from: &redoStack, to: &undoStack) }

    private func stepHistory(from source: inout [TransformSnapshot], to target: inout [TransformSnapshot]) {
        guard let snap = source.popLast(),
              let object = scene?.objects.first(where: { $0.id == snap.objectID }),
              let current = snapshot(of: object, instance: snap.instance) else { updateUndoFlags(); return }
        target.append(current)
        updateUndoFlags()
        transform(objectID: snap.objectID, instance: snap.instance, offset: snap.offset,
                  rotationDeg: snap.rotationDeg, scale: snap.scale, recordUndo: false)
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Déplacement d'un pas (flèches du clavier ; ⇧ = 10 mm), borné au plateau.
    func nudgeSelected(dx: Double, dy: Double) {
        guard let object = selectedObject, let inst = object.instances.first, let bed = scene?.bed else { return }
        let shift = BedBounds.clampingShift(min: Vec3(inst.min[0] + dx, inst.min[1] + dy, inst.min[2]),
                                            max: Vec3(inst.max[0] + dx, inst.max[1] + dy, inst.max[2]), bed: bed)
        transform(objectID: object.id, offset: [inst.offset[0] + dx + shift.x, inst.offset[1] + dy + shift.y, inst.offset[2]])
    }

    func duplicateSelected() {
        guard let object = selectedObject else { return }
        setInstanceCount(object.instances.count + 1, objectID: object.id)
    }

    func deleteSelected() {
        guard let id = selectedObjectID else { return }
        mutateScene { try $0.removeObject(id) }
        selectedObjectID = nil
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
        guard let object = selectedObject, let inst = object.instances.first else { return }
        transform(objectID: object.id, scale: inst.scale.map { $0 * factor }, dropToBed: true)
    }

    func layOnFace(objectID: UInt64, triangle: Int) {
        layOnFaceMode = false
        mutateScene { try $0.layOnFace(objectID: objectID, triangle: triangle) }
    }

    func clearScene() {
        mutateScene { try $0.clearScene() }
        selectedObjectID = nil
        meshes.removeAll()
        output = nil; summary = nil; gcodeMesh = nil; gcodeMoves = []
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
                    return (summary, try core.gcodeMoves().map(GCodeMove.init))
                }
                relay.stop()
                let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
                summary = result.0
                gcodeMoves = result.1
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
        guard !gcodeMoves.isEmpty else { gcodeMesh = nil; return }
        rebuildTask?.cancel()
        var builder = GCodeMeshBuilder()
        builder.mode = colorMode
        builder.hiddenRoles = hiddenRoles
        builder.includeTravel = showTravel
        let moves = gcodeMoves
        let configured = builder   // copie immuable : capturée par la tâche détachée
        rebuildTask = Task {
            let mesh = await Task.detached(priority: .userInitiated) { configured.build(moves: moves) }.value
            guard !Task.isCancelled else { return }
            gcodeMesh = mesh
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

    func refreshPrinterStatus() {
        guard moonraker.isConfigured else { return }
        let client = MoonrakerClient(config: moonraker)
        Task {
            do {
                printerStatus = try await client.status()
                if !isUploading { uploadStatus = nil }
            } catch {
                printerStatus = nil
                uploadStatus = error.localizedDescription
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
