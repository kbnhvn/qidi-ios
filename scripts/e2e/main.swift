//
//  main.swift — test de bout en bout du *vrai* SlicerModel (et de l'enveloppe Swift de l'ABI C)
//  contre le *vrai* moteur et le *vrai* bundle QIDI, sous Linux.
//
//  Ce que ça prouve : la logique de l'app (sélection de presets, scène, annuler/rétablir,
//  réglages, slicing, aperçu, calibration, préréglages, export/import de profil) fonctionne de
//  bout en bout. Ce que ça ne prouve pas : SwiftUI, SceneKit, les gestes (substituts Linux).
//
//    scripts/e2e-linux.sh
//
import Foundation

var failures = 0
func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print(String(format: "  %-70@ %@", label as NSString, (ok ? "ok" : "ÉCHEC " + detail) as NSString))
    if !ok { failures += 1 }
}

@MainActor
func waitUntil(_ timeout: Double = 120, _ label: String, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
    print("  (délai dépassé : \(label))")
    return false
}

@MainActor
func run() async -> Int32 {
    setvbuf(stdout, nil, _IONBF, 0)   // la sortie reste lisible si le programme plante
    let env = ProcessInfo.processInfo.environment
    guard let resources = env["QSID_RESOURCES_DIR"], let config = env["QSID_CONFIG_DIR"], let out = env["QSID_E2E_OUT"] else {
        print("variables attendues : QSID_RESOURCES_DIR, QSID_CONFIG_DIR, QSID_E2E_OUT, QSID_TESTDATA")
        return 2
    }
    let testdata = URL(fileURLWithPath: env["QSID_TESTDATA"] ?? "testdata")
    let outDir = URL(fileURLWithPath: out)
    try? FileManager.default.removeItem(at: outDir)
    for sub in ["data", "exports", "work"] {
        try? FileManager.default.createDirectory(at: outDir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    // état persistant vierge
    for key in ["qsid.printer", "qsid.print", "qsid.filament", "qsid.overrides.v2", "qsid.userPresets", "qsid.moonraker"] {
        UserDefaults.standard.removeObject(forKey: key)
    }

    let locations = SlicerLocations(
        resourcesDirectory: URL(fileURLWithPath: resources),
        dataDirectory: outDir.appendingPathComponent("data"),
        exportsDirectory: outDir.appendingPathComponent("exports"),
        workDirectory: outDir.appendingPathComponent("work"),
        configPagesURL: URL(fileURLWithPath: config).appendingPathComponent("config_pages.json"),
        configFrenchURL: URL(fileURLWithPath: config).appendingPathComponent("config_fr.json"))

    print("démarrage")
    let model = SlicerModel(locations: locations)
    let ready = await waitUntil(120, "presets") { model.presetsReady }
    check(ready, "profils chargés par le moteur (PresetBundle)", model.errorMessage ?? "")
    check(model.printers.count == 24, "24 imprimantes", "\(model.printers.count)")
    check(model.selection.printer.contains("0.4"), "imprimante par défaut : buse 0,4 mm", model.selection.printer)
    check(model.selection.print.hasPrefix("0.20mm"), "preset d'impression ≈ buse/2", model.selection.print)
    check(model.selection.filament.hasPrefix("QIDI PLA"), "filament par défaut : QIDI PLA", model.selection.filament)
    check(model.filamentPresets.allSatisfy { $0.hasSuffix("@" + model.selection.printer) },
          "filaments proposés : ceux de l'imprimante", "\(model.filamentPresets.count)")
    check(model.printPresets.allSatisfy { $0.hasSuffix("@" + model.selection.printer) },
          "presets d'impression compatibles avec la buse")
    check(model.scene?.bed.width == 270, "plateau Q2 : 270 mm", "\(String(describing: model.scene?.bed.width))")
    check(model.baseConfig["use_relative_e_distances"] == "1", "configuration du preset lue (extrusion relative)")

    print("changer d'imprimante")
    model.selectPrinter("X-Plus 3 0.6 nozzle")
    _ = await waitUntil(60, "X-Plus 3") { model.selection.printer == "X-Plus 3 0.6 nozzle" && model.scene?.bed.width == 280 }
    check(model.selection.printer == "X-Plus 3 0.6 nozzle" && model.scene?.bed.width == 280, "plateau X-Plus 3 : 280 mm",
          "\(String(describing: model.scene?.bed.width))")
    check(model.selection.print.hasSuffix("@X-Plus 3 0.6 nozzle"), "preset d'impression suit la buse", model.selection.print)
    check(model.selection.filament.hasSuffix("@X-Plus 3 0.6 nozzle"), "filament suit la buse", model.selection.filament)
    check(UserDefaults.standard.string(forKey: "qsid.printer") == "X-Plus 3 0.6 nozzle", "sélection persistée")
    model.selectPrinter("Q2 0.4 nozzle")
    _ = await waitUntil(60, "retour Q2") { model.selection.printer == "Q2 0.4 nozzle" && model.scene?.bed.width == 270 }

    print("scène")
    model.importModel(from: testdata.appendingPathComponent("cube_20mm.stl"))
    let imported = await waitUntil(60, "import") { model.scene?.objects.count == 1 && model.selectedObjectID != nil }
    check(imported, "import : un objet, sélectionné")
    guard let obj = model.selectedObject, let first = obj.instances.first else { print("pas d'objet"); return 1 }
    check(first.min[2] == 0 && !first.outside, "posé sur le plateau, dans le volume")
    check(model.meshes[obj.id]?.count == 12 * 9, "maillage local : 12 triangles")

    model.importModel(from: testdata.appendingPathComponent("cube_20mm_z30.stl"))
    _ = await waitUntil(60, "second import") { model.scene?.objects.count == 2 }
    check(model.scene?.objects.count == 2, "second import")
    let a = model.scene!.objects[0].instances[0], b = model.scene!.objects[1].instances[0]
    check(a.max[0] <= b.min[0] || b.max[0] <= a.min[0] || a.max[1] <= b.min[1] || b.max[1] <= a.min[1],
          "les deux objets ne se chevauchent pas")
    check(b.min[2] == 0, "cube décalé en Z posé sur le plateau")

    model.selectedObjectID = obj.id
    let before = model.scene!.objects[0].instances[0].offset
    model.transform(objectID: obj.id, offset: [100, 120, before[2]])
    _ = await waitUntil(30, "déplacement") { model.scene?.objects[0].instances[0].offset[0] == 100 }
    check(model.scene?.objects[0].instances[0].offset == [100, 120, before[2]], "déplacement validé par le moteur")
    check(model.canUndo, "annulation disponible")
    model.undo()
    _ = await waitUntil(30, "annuler") { model.scene?.objects[0].instances[0].offset[0] == before[0] }
    check(model.scene?.objects[0].instances[0].offset == before, "annuler ramène la position d'origine")
    check(model.canRedo, "rétablissement disponible")
    model.redo()
    _ = await waitUntil(30, "rétablir") { model.scene?.objects[0].instances[0].offset[0] == 100 }
    check(model.scene?.objects[0].instances[0].offset[0] == 100, "rétablir rejoue le déplacement")

    model.transform(objectID: obj.id, offset: [900, 900, before[2]])
    _ = await waitUntil(30, "hors plateau") { model.scene?.hasObjectOutsideBed == true }
    check(model.scene?.hasObjectOutsideBed == true, "objet hors plateau détecté")
    model.slice()
    check(!model.isSlicing && model.errorMessage != nil, "slicing refusé avec un objet hors plateau", model.errorMessage ?? "")
    model.errorMessage = nil
    model.arrange()
    _ = await waitUntil(60, "organiser") { model.scene?.hasObjectOutsideBed == false }
    check(model.scene?.hasObjectOutsideBed == false, "« Organiser » ramène tout dans le plateau")

    model.nudgeSelected(dx: 10, dy: 0)
    let nudged = model.scene!.objects.first { $0.id == obj.id }!.instances[0].offset[0]
    _ = await waitUntil(30, "pas clavier") { model.scene!.objects.first { $0.id == obj.id }!.instances[0].offset[0] != nudged }
    model.deleteSelected()
    _ = await waitUntil(30, "suppression") { model.scene?.objects.count == 1 }
    check(model.scene?.objects.count == 1 && model.selectedObjectID == nil, "suppression de l'objet sélectionné")

    print("manipulation avancée")
    guard let keep = model.scene?.objects.first?.id else { return 1 }
    model.selectedObjectID = keep
    model.transform(objectID: keep, rotationDeg: [35, 20, 10], dropToBed: true)
    _ = await waitUntil(30, "inclinaison") { model.scene?.objects.first?.instances.first?.rotationDeg == [35, 20, 10] }
    check(model.scene?.objects.first?.instances.first?.rotationDeg == [35, 20, 10], "rotation 3 axes appliquée")
    check(model.scene?.objects.first?.instances.first?.min[2] == 0, "reste posé sur le plateau après rotation")
    model.layOnFace(objectID: keep, triangle: 0)
    _ = await waitUntil(30, "poser sur une face") { model.scene?.objects.first?.instances.first?.rotationDeg != [35, 20, 10] }
    let laid = model.scene!.objects.first!.instances.first!
    check(laid.min[2] == 0 && abs(laid.size[2] - 20) < 0.01, "« poser sur une face » : le cube repose sur une face (hauteur 20 mm)", "\(laid.size)")
    model.resetRotation(keep)
    _ = await waitUntil(30, "orientation d'origine") { model.scene?.objects.first?.instances.first?.rotationDeg == [0, 0, 0] }
    check(model.scene?.objects.first?.instances.first?.rotationDeg == [0, 0, 0], "orientation d'origine rétablie")
    model.duplicateSelected()
    _ = await waitUntil(30, "copie") { model.scene?.objects.first?.instances.count == 2 }
    check(model.scene?.objects.first?.instances.count == 2, "copie (deuxième instance)")
    check(model.scene?.hasObjectOutsideBed == false, "la copie est dans le plateau")
    model.setInstanceCount(1, objectID: keep)
    _ = await waitUntil(30, "une seule instance") { model.scene?.objects.first?.instances.count == 1 }
    model.scaleSelected(by: 2)
    _ = await waitUntil(30, "échelle") { (model.scene?.objects.first?.instances.first?.size[0] ?? 0) > 39 }
    check(abs((model.scene?.objects.first?.instances.first?.size[0] ?? 0) - 40) < 0.01, "échelle ×2 : 40 mm")
    model.scaleSelected(by: 0.5)
    _ = await waitUntil(30, "échelle ½") { (model.scene?.objects.first?.instances.first?.size[0] ?? 0) < 21 }

    print("avertissement d'unités")
    model.importModel(from: testdata.appendingPathComponent("cube_0p8mm_inches.stl"))
    _ = await waitUntil(30, "alerte") { model.sceneAlerts != nil }
    check(model.sceneAlerts?.imperial == true || model.sceneAlerts?.savedInMeters == true, "un modèle minuscule déclenche l'alerte d'unités",
          "\(String(describing: model.sceneAlerts))")
    model.scaleSelected(by: 25.4)
    _ = await waitUntil(30, "conversion") { (model.selectedObject?.instances.first?.size[0] ?? 0) > 15 }
    check(abs((model.selectedObject?.instances.first?.size[0] ?? 0) - 20.32) < 0.05, "conversion pouces → mm (×25,4)")
    model.deleteSelected()
    _ = await waitUntil(30, "suppression du petit cube") { model.scene?.objects.count == 1 }

    print("multi-sélection")
    model.importModel(from: testdata.appendingPathComponent("cube_20mm.stl"))
    _ = await waitUntil(30, "second cube") { model.scene?.objects.count == 2 }
    check(model.scene?.objects.count == 2, "second cube importé")
    model.selectAll()
    check(model.selectedObjectIDs.count == 2 && model.hasMultipleSelected, "⌘A sélectionne tous les objets")
    let xs0 = model.scene!.objects.map { $0.instances[0].offset[0] }
    model.nudgeSelected(dx: 5, dy: 0)
    _ = await waitUntil(30, "pas de groupe") { model.scene!.objects.map { $0.instances[0].offset[0] } != xs0 }
    let xs1 = model.scene!.objects.map { $0.instances[0].offset[0] }
    check(zip(xs0, xs1).allSatisfy { abs($1 - $0 - 5) < 1e-6 }, "le groupe bouge d'un bloc", "\(xs0) -> \(xs1)")
    model.undo()
    _ = await waitUntil(30, "annulation de groupe") { model.scene!.objects.map { $0.instances[0].offset[0] } == xs0 }
    check(model.scene!.objects.map { $0.instances[0].offset[0] } == xs0, "un seul « annuler » ramène tout le groupe")
    let second = model.scene!.objects[1].id
    model.toggleSelection(second)
    check(model.selectedObjectIDs == [keep] && model.selectedObjectID == keep, "retirer un objet de la sélection")
    model.toggleSelection(second)
    check(model.selectedObjectIDs.count == 2 && model.selectedObjectID == second, "ajouter un objet à la sélection")
    model.selectedObjectID = second
    check(model.selectedObjectIDs == [second], "choisir un objet remplace la sélection")
    model.deleteSelected()
    _ = await waitUntil(30, "suppression du second") { model.scene?.objects.count == 1 }
    check(model.scene?.objects.map(\.id) == [keep] && model.selectedObjectIDs.isEmpty, "suppression de la sélection")
    model.selectedObjectID = keep

    print("réglages par objet")
    func object() -> SceneObject? { model.scene?.objects.first { $0.id == keep } }
    model.setObjectOption("fill_density", "100%", objectID: keep)
    _ = await waitUntil(30, "réglage d'objet") { object()?.config["fill_density"] != nil }
    check(object()?.config["fill_density"] == "100%" && model.isObjectOptionModified("fill_density", objectID: keep),
          "réglage d'objet enregistré par le moteur")
    model.undo()
    _ = await waitUntil(30, "annuler le réglage") { object()?.config["fill_density"] == nil }
    check(object()?.config["fill_density"] == nil && model.canRedo, "annuler retire le réglage d'objet")
    model.redo()
    _ = await waitUntil(30, "rétablir le réglage") { object()?.config["fill_density"] == "100%" }
    check(object()?.config["fill_density"] == "100%", "rétablir le remet")
    check(model.objectValue(of: "fill_density", objectID: keep) == "100%", "valeur effective de l'objet")
    check(model.objectValue(of: "perimeters", objectID: keep) == model.value(of: "perimeters"), "sinon la valeur globale")
    check(object()?.hasCustomSettings == true, "l'objet est signalé comme personnalisé")
    model.addModifier(objectID: keep, shape: .cylinder, kind: .modifier)
    _ = await waitUntil(30, "modificateur") { object()?.modifiers.count == 1 }
    let mod = object()!.modifiers[0]
    check(mod.name == "cylinder" && mod.kind == "modifier", "modificateur cylindre ajouté")
    model.setObjectOption("perimeters", "6", objectID: keep, volumeID: mod.id)
    _ = await waitUntil(30, "réglage du modificateur") { object()?.modifiers.first?.config["perimeters"] != nil }
    check(object()?.modifiers.first?.config["perimeters"] == "6", "réglage du modificateur")
    model.updateModifier(objectID: keep, volumeID: mod.id, centerWorld: nil, size: [5, 5, 5])
    _ = await waitUntil(30, "taille du modificateur") { object()?.modifiers.first?.size == [5, 5, 5] }
    check(object()?.modifiers.first?.size == [5, 5, 5], "modificateur redimensionné")
    model.addModifier(objectID: keep, shape: .box, kind: .supportBlocker)
    _ = await waitUntil(30, "bloqueur") { object()?.modifiers.count == 2 }
    check(object()?.modifiers.last?.kind == "blocker", "bloqueur de supports ajouté")
    model.addLayerRange(objectID: keep)
    _ = await waitUntil(30, "plage") { object()?.layerRanges.count == 1 }
    check(object()?.layerRanges.first?.config["layer_height"] != nil, "plage de hauteurs créée avec la hauteur de couche")
    let range = object()!.layerRanges[0]
    model.moveLayerRange(objectID: keep, from: range, minZ: 2, maxZ: 8)
    _ = await waitUntil(30, "plage déplacée") { object()?.layerRanges.first?.min == 2 }
    check(object()?.layerRanges.first?.max == 8 && object()?.layerRanges.first?.config["layer_height"] != nil,
          "bornes changées, réglages conservés")
    model.slice()
    _ = await waitUntil(300, "slicing avec réglages d'objet") { !model.isSlicing && model.output != nil }
    check(model.output != nil && model.errorMessage == nil, "l'objet personnalisé se slice", model.errorMessage ?? "")
    model.resetObjectOption(nil, objectID: keep)
    for volume in object()!.modifiers { model.removeModifier(objectID: keep, volumeID: volume.id) }
    model.removeLayerRange(objectID: keep, minZ: 2, maxZ: 8)
    _ = await waitUntil(30, "nettoyage") { object()?.hasCustomSettings == false }
    check(object()?.hasCustomSettings == false, "réglages, modificateurs et plages retirés")

    print("coupe et simplification")
    model.beginCut()
    check(model.cutPlane?.axis == .z && abs((model.cutPlane?.position ?? 0) - 10) < 1e-6, "plan de coupe au milieu de l'objet")
    model.applyCut(keep: .both, placeOnCut: false)
    _ = await waitUntil(60, "coupe") { model.scene?.objects.count == 2 }
    check(model.scene?.objects.count == 2 && model.cutPlane == nil, "la coupe donne deux objets")
    let heights = model.scene!.objects.map { $0.instances[0].size[2] }
    check(heights.allSatisfy { abs($0 - 10) < 0.05 }, "deux moitiés de 10 mm", "\(heights)")
    check(model.selectedObjectIDs.count == 2, "les moitiés sont sélectionnées")
    check(model.scene?.hasObjectOutsideBed == false, "les moitiés sont dans le volume d'impression")
    model.undo()
    _ = await waitUntil(30, "annuler la coupe") { model.scene?.objects.count == 1 }
    check(model.scene?.objects.map(\.id) == [keep], "annuler la coupe rend l'objet d'origine (même identifiant)", "\(String(describing: model.scene?.objects.map(\.id)))")
    model.redo()
    _ = await waitUntil(30, "rétablir la coupe") { model.scene?.objects.count == 2 }
    check(model.scene?.objects.count == 2, "rétablir la coupe")
    model.selectedObjectID = model.scene?.objects.first?.id
    model.beginCut(axis: .x)
    model.applyCut(keep: .upper, placeOnCut: true)
    _ = await waitUntil(60, "seconde coupe") { model.scene?.objects.count == 2 && model.cutPlane == nil && model.selectedObjectIDs.count == 1 }
    check(model.scene?.objects.count == 2, "coupe verticale en gardant un côté : un objet remplacé par un seul")
    model.clearScene()
    _ = await waitUntil(30, "plateau vidé") { model.scene?.objects.isEmpty == true }
    model.importModel(from: testdata.appendingPathComponent("sphere_r10.stl"))
    _ = await waitUntil(60, "sphère") { model.scene?.objects.count == 1 }
    let sphere = model.scene!.objects[0]
    model.simplify(objectID: sphere.id, ratio: 0.25)
    _ = await waitUntil(120, "simplification") { (model.scene?.objects.first?.triangles ?? Int.max) < sphere.triangles }
    check((model.scene?.objects.first?.triangles ?? Int.max) < sphere.triangles / 2, "maillage simplifié",
          "\(sphere.triangles) -> \(model.scene?.objects.first?.triangles ?? -1)")
    check(model.meshes[sphere.id]?.count == (model.scene?.objects.first?.triangles ?? -1) * 9, "le maillage affiché suit la simplification")
    model.undo()
    _ = await waitUntil(60, "annuler la simplification") { model.scene?.objects.first?.triangles == sphere.triangles }
    check(model.scene?.objects.first?.triangles == sphere.triangles && model.meshes[sphere.id]?.count == sphere.triangles * 9,
          "annuler la simplification rend le maillage d'origine")
    model.clearScene()
    _ = await waitUntil(30, "plateau vidé 2") { model.scene?.objects.isEmpty == true }
    model.importModel(from: testdata.appendingPathComponent("cube_20mm.stl"))
    _ = await waitUntil(30, "cube de reprise") { model.scene?.objects.count == 1 }
    model.selectedObjectID = model.scene?.objects.first?.id

    print("réglages")
    var infill15 = 0.0, infill40 = 0.0
    do {
        // le même objet avec deux densités : plus de remplissage = plus de filament
        model.slice()
        _ = await waitUntil(300, "slicing 1") { model.output != nil && !model.isSlicing }
        infill15 = model.summary?.filamentG ?? 0
        check(model.output != nil && model.summary != nil, "slicing : G-code et résumé")
        check(FileManager.default.fileExists(atPath: model.output?.url.path ?? ""), "G-code écrit dans le dossier d'export")
        check(model.workspace == .preview, "bascule en mode Aperçu")
        check(!model.resultIsStale, "résultat à jour")
        _ = await waitUntil(60, "géométrie d'aperçu") { model.gcodeMesh != nil }
        check(model.gcodeMesh != nil, "géométrie d'aperçu construite à partir des mouvements du moteur")
        check(model.gcodeMesh?.layers.count == model.summary?.layers, "une géométrie par couche",
              "\(String(describing: model.gcodeMesh?.layers.count)) vs \(String(describing: model.summary?.layers))")
        let roles = model.summary?.roles.map(\.name) ?? []
        check(roles.contains("external_perimeter") && roles.contains("internal_infill"), "légende : types d'extrusion", "\(roles)")

        model.setOption("fill_density", "40%")
        check(model.overrides.isModified("fill_density"), "réglage forcé enregistré")
        _ = await waitUntil(10, "péremption") { model.resultIsStale }
        check(model.resultIsStale, "l'aperçu est signalé obsolète après un changement de réglage")
        model.slice()
        _ = await waitUntil(300, "slicing 2") { !model.isSlicing && !model.resultIsStale }
        infill40 = model.summary?.filamentG ?? 0
        check(infill40 > infill15, "40 % de remplissage consomme plus que le preset", "\(infill15) → \(infill40)")
        model.resetOption("fill_density")
    }

    model.overrides.setSupportMode(.buildPlateOnly, base: model.baseConfig)
    model.overrides.setAdhesion(.brim, base: model.baseConfig)
    check(model.overrides.supportMode(base: model.baseConfig) == .buildPlateOnly, "supports : sur le plateau uniquement")
    check(model.overrides.summary(base: model.baseConfig)?.contains("brim") == true, "résumé des réglages")
    let parentPrint = model.selection.print
    model.saveUserPreset(named: "Mon essai")
    check(model.userPresets.keys.contains("Mon essai"), "préréglage enregistré")
    check(model.userPresets["Mon essai"]?.print == parentPrint && model.userPresets["Mon essai"]?.printer == model.selection.printer
          && model.userPresets["Mon essai"]?.filament == model.selection.filament, "il mémorise ses presets parents")
    check(model.activeUserPreset == "Mon essai" && !model.isUserPresetModified, "préréglage actif, non modifié")
    model.overrides.setInfillPercent(60, base: model.baseConfig)
    check(model.isUserPresetModified, "un réglage changé est signalé « modifié »")
    model.updateActiveUserPreset()
    check(!model.isUserPresetModified && model.userPresets["Mon essai"]?.overrides.infillPercent(base: model.baseConfig) == 60, "« mettre à jour » enregistre")
    let otherPrint = model.printPresets.first { $0 != parentPrint }
    check(otherPrint != nil, "un autre preset d'impression existe")
    if let otherPrint {
        model.selectPrint(otherPrint)
        _ = await waitUntil(60, "autre preset") { model.selection.print == otherPrint }
        check(model.isUserPresetModified, "changer le preset parent est signalé")
    }
    model.overrides.resetAll()
    check(model.overrides.isEmpty, "réglages remis au preset")
    model.applyUserPreset("Mon essai")
    _ = await waitUntil(60, "rappel") { model.selection.print == parentPrint && model.overrides.infillPercent(base: model.baseConfig) == 60 }
    check(model.selection.print == parentPrint, "rappeler le préréglage rétablit le preset parent", model.selection.print)
    check(model.overrides.infillPercent(base: model.baseConfig) == 60, "… et ses réglages")
    check(!model.isUserPresetModified, "rappelé : plus modifié")
    check(model.saveUserPreset(named: "Mon essai", replacing: false) == "Mon essai 2", "« enregistrer sous » ne remplace pas")
    model.deleteUserPreset("Mon essai 2")
    model.deleteUserPreset("Mon essai")
    check(model.userPresets.isEmpty && model.activeUserPreset == nil, "préréglages supprimés")
    model.overrides.resetAll()

    L10n.language = "fr"
    await model.loadSettingsCatalog()
    check((model.settingsCatalog?.options.count ?? 0) > 300, "catalogue des réglages chargé depuis le moteur", "\(model.settingsCatalog?.options.count ?? 0)")
    check(model.settingsCatalog?.label(model.settingsCatalog!.options["layer_height"]!) == "Hauteur de couche", "libellés en français")

    print("envoi à l'imprimante (Moonraker simulé)")
    if let base = env["QSID_MOCK_MOONRAKER"], let url = URL(string: base), let port = url.port,
       let journalPath = env["QSID_MOCK_JOURNAL"] {
        // le résultat courant : celui de « slicing 2 » ou plus tard ; on s'assure d'en avoir un à jour
        if model.output == nil || model.resultIsStale {
            model.slice()
            _ = await waitUntil(300, "slicing avant envoi") { model.output != nil && !model.isSlicing && !model.resultIsStale }
        }
        model.moonraker = MoonrakerConfig(host: "127.0.0.1", port: port, apiKey: "secret-test")
        check(model.moonraker.isConfigured, "imprimante configurée")
        model.refreshPrinterStatus()
        _ = await waitUntil(15, "état") { model.printerStatus != nil }
        check(model.printerStatus?.state == "standby" && model.printerStatus?.nozzle == 219.6, "état lu (repos, 219,6 °C)",
              "\(String(describing: model.printerStatus))")
        let expectedSize = model.output?.sizeBytes ?? -1
        let expectedName = model.output?.url.lastPathComponent ?? ""
        var sawProgress = false
        model.uploadAndPrint()
        let done = await waitUntil(60, "envoi") {
            if let p = model.uploadProgress, p > 0 { sawProgress = true }
            return model.uploadStatus == "Impression lancée."
        }
        check(done, "envoi terminé et impression lancée", model.errorMessage ?? "\(String(describing: model.uploadStatus))")
        let journal = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: journalPath)))) as? [String: Any]
        let uploads = journal?["uploads"] as? [[String: Any]] ?? []
        check(uploads.count == 1, "un fichier reçu par l'imprimante")
        check(uploads.first?["filename"] as? String == expectedName, "nom de fichier", "\(String(describing: uploads.first?["filename"]))")
        check(uploads.first?["root"] as? String == "gcodes", "dépôt dans « gcodes »")
        check((uploads.first?["size"] as? Int).map(Int64.init) == expectedSize, "taille reçue = taille du G-code",
              "\(String(describing: uploads.first?["size"])) vs \(expectedSize)")
        check((uploads.first?["head"] as? String)?.hasPrefix(";") == true, "contenu : G-code (commentaire en tête)")
        check((journal?["started"] as? [String])?.first == expectedName, "démarrage demandé pour ce fichier")
        check((journal?["api_keys"] as? [String])?.allSatisfy { $0 == "secret-test" } == true, "clé API envoyée")
        _ = await waitUntil(15, "état après envoi") { model.printerStatus?.state == "printing" }
        check(model.printerStatus?.state == "printing" && model.printerStatus?.progress == 0.5, "état : impression en cours à 50 %")
        _ = sawProgress   // la progression est un événement rapide : on ne l'exige pas sur un envoi local

        print("découverte des imprimantes")
        model.startDiscovery(hosts: ["127.0.0.1", "192.0.2.1"], port: port)
        check(model.isDiscovering, "recherche en cours")
        _ = await waitUntil(60, "découverte") { !model.isDiscovering }
        check(model.discoveredPrinters.count == 1, "une imprimante trouvée (l'autre adresse ne répond pas)", "\(model.discoveredPrinters)")
        let found = model.discoveredPrinters.first
        check(found?.host == "127.0.0.1" && found?.port == port, "adresse et port", "\(String(describing: found))")
        check(found?.hostname == "qidi-mock" && found?.version == "v0.8.0-test" && found?.klippyState == "ready", "nom d'hôte, version, état Klipper")
        model.moonraker = MoonrakerConfig(host: "", port: 7125, apiKey: "secret-test")
        if let found { model.usePrinter(found) }
        check(model.moonraker.host == "127.0.0.1" && model.moonraker.port == port && model.moonraker.apiKey == "secret-test",
              "« utiliser » reprend l'adresse et garde la clé API")
        model.startDiscovery(hosts: ["192.0.2.1"], port: port)
        _ = await waitUntil(30, "recherche vide") { !model.isDiscovering }
        check(model.discoveredPrinters.isEmpty, "aucune imprimante sur une adresse qui ne répond pas")

        print("multi-filament et QIDI Box")
        model.setExtruderCount(3)
        _ = await waitUntil(60, "3 filaments") { model.extruderFilaments.count == 3 }
        check(model.isMultiFilament && model.extruderCount == 3, "3 extrudeurs")
        check(model.baseConfig["nozzle_diameter"]?.split(separator: ",").count == 3, "la configuration suit : 3 buses", model.baseConfig["nozzle_diameter"] ?? "nil")
        check(model.filamentColors.count == 3, "3 couleurs de filament")
        let other = model.filamentPresets.first { $0 != model.selection.filament && $0.contains("ABS") } ?? model.filamentPresets.last!
        model.setExtruderFilament(1, other)
        _ = await waitUntil(60, "filament T2") { model.extruderFilaments.count == 3 && model.extruderFilaments[1] == other }
        check(model.extruderFilaments[1] == other, "filament du deuxième extrudeur", "\(model.extruderFilaments)")
        model.setFilamentColor(2, hex: "#FF0000")
        _ = await waitUntil(30, "couleur T3") { model.filamentColors.count == 3 && model.filamentColors[2] == "#FF0000" }
        check(model.filamentColors[2] == "#FF0000", "couleur du troisième filament", "\(model.filamentColors)")
        model.importModel(from: testdata.appendingPathComponent("cube_20mm.stl"))
        _ = await waitUntil(30, "second cube multi") { (model.scene?.objects.count ?? 0) >= 2 }
        let second2 = model.scene!.objects.last!.id
        model.setObjectOption("extruder", "2", objectID: second2)
        _ = await waitUntil(30, "extrudeur de l'objet") { model.scene?.objects.last?.config["extruder"] == "2" }
        check(model.scene?.objects.last?.config["extruder"] == "2", "objet affecté au deuxième filament")
        model.slice()
        _ = await waitUntil(300, "slicing multi-filament") { !model.isSlicing && model.output != nil && !model.resultIsStale }
        check(model.errorMessage == nil && model.summary != nil, "slicing multi-filament", model.errorMessage ?? "")
        check(model.usedExtruders.contains(0) && model.usedExtruders.contains(1), "les deux outils sont utilisés", "\(model.usedExtruders)")
        check((model.summary?.toolchanges ?? 0) >= 1, "changement d'outil compté", "\(String(describing: model.summary?.toolchanges))")
        model.colorMode = .tool
        _ = await waitUntil(60, "aperçu par outil") { model.gcodeMesh != nil && model.gcodeMesh?.valueRange == nil }
        check(model.gcodeMesh != nil, "aperçu coloré par filament")

        model.useBox = true
        model.boxSlots = [4, 5, 6]
        let before = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: journalPath)))) as? [String: Any]
        let startedBefore = (before?["started"] as? [String])?.count ?? 0
        model.uploadAndPrint()
        _ = await waitUntil(60, "envoi multi") { model.uploadStatus == "Impression lancée." && ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: journalPath)))) as? [String: Any]).flatMap { ($0["started"] as? [String])?.count } ?? 0 > startedBefore }
        let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: journalPath)))) as? [String: Any]
        let scripts = after?["scripts"] as? [String] ?? []
        check(scripts.first == "SAVE_VARIABLE VARIABLE=enable_box VALUE=1", "le Box est activé avant le démarrage", "\(scripts)")
        check(scripts.contains(#"SAVE_VARIABLE VARIABLE=value_t0 VALUE=\"'slot4'\""#) && scripts.contains(#"SAVE_VARIABLE VARIABLE=value_t2 VALUE=\"'slot6'\""#),
              "chaque outil est associé à son emplacement", "\(scripts)")
        let vars = after?["variables"] as? [String: Any] ?? [:]
        check(vars["enable_box"] as? Int == 1 && vars["value_t1"] as? String == "'slot5'", "variables Klipper enregistrées", "\(vars)")
        model.boxSlots = [0, 0, 0]
        model.useBox = false
        model.readBoxFromPrinter()
        _ = await waitUntil(30, "lecture du Box") { model.boxSlots == [4, 5, 6] }
        check(model.boxSlots == [4, 5, 6] && model.useBox, "association relue depuis l'imprimante", "\(model.boxSlots)")
        model.setExtruderCount(1)
        _ = await waitUntil(60, "retour mono-filament") { !model.isMultiFilament }
        check(!model.isMultiFilament && model.baseConfig["nozzle_diameter"]?.contains(",") == false, "retour à un seul filament")
        model.useBox = false
        model.colorMode = .featureType
    } else {
        print("  (ignoré : QSID_MOCK_MOONRAKER absent)")
    }

    print("annulation du slicing")
    model.importModel(from: testdata.appendingPathComponent("cube_20mm.stl"))
    _ = await waitUntil(30, "second cube") { model.scene?.objects.count == 2 }
    model.slice()
    _ = await waitUntil(30, "démarrage") { model.isSlicing }
    model.cancel()
    _ = await waitUntil(300, "fin ou annulation") { !model.isSlicing }
    check(!model.isSlicing, "après « Annuler », l'app n'est pas bloquée")
    model.slice()
    _ = await waitUntil(300, "slicing après annulation") { model.output != nil && !model.isSlicing && !model.resultIsStale }
    check(model.output != nil && !model.resultIsStale, "un nouveau slicing réussit après une annulation")

    print("persistance (relance de l'app)")
    let before2 = (model.selection, model.overrides)
    model.overrides.setInfillPercent(35, base: model.baseConfig)
    try? await Task.sleep(nanoseconds: 400_000_000)
    let relaunched = SlicerModel(locations: locations)
    _ = await waitUntil(120, "relance") { relaunched.presetsReady }
    check(relaunched.selection == before2.0, "imprimante, preset et filament retrouvés", "\(relaunched.selection) vs \(before2.0)")
    check(relaunched.overrides.infillPercent(base: relaunched.baseConfig) == 35, "réglages retrouvés")
    model.overrides.resetAll()

    print("export / import de profil")
    model.setOption("perimeters", "3")
    model.prepareConfigExport()
    _ = await waitUntil(30, "export .ini") { model.exportedConfigURL != nil }
    let exported = model.exportedConfigURL
    let text = exported.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    check(text.contains("perimeters = 3"), "le .ini exporté contient les réglages forcés")
    check(text.contains("gcode_flavor = klipper"), "le .ini exporté contient la config du preset")
    model.overrides.resetAll()
    if let exported {
        model.importProfile(from: exported)
        _ = await waitUntil(60, "import profil") { model.importedProfile != nil }
        check(model.importedProfile != nil && model.baseConfig["perimeters"] == "3", "profil .ini importé : devient la base", model.baseConfig["perimeters"] ?? "nil")
        model.clearProfile()
        _ = await waitUntil(60, "retour presets") { model.importedProfile == nil && model.baseConfig["perimeters"] != "3" }
        check(model.importedProfile == nil && model.baseConfig["perimeters"] != "3", "retour aux presets embarqués")
    }

    print("calibration")
    model.startCalibration(.pressureAdvanceTower(start: 0, end: 0.04, step: 0.002))
    _ = await waitUntil(60, "tour PA") { model.calibration != nil && model.scene?.objects.count == 1 }
    check(model.calibration != nil && model.scene?.objects.count == 1, "tour PA importée, plateau remplacé")
    if let tower = model.scene?.objects.first?.instances.first {
        check(abs(tower.size[2] - 105) < 0.2, "tour à la hauteur de 21 marches de 5 mm", "\(tower.size[2])")
    }
    check(model.overrides.isModified("before_layer_gcode"), "réglage temporaire : before_layer_gcode")
    model.slice()
    _ = await waitUntil(300, "slicing PA") { model.output != nil && !model.isSlicing && !model.resultIsStale }
    let gcode = (try? String(contentsOf: model.output!.url, encoding: .utf8)) ?? ""
    let k = gcode.split(separator: "\n").filter { $0.hasPrefix("M900 K") }.compactMap { Double($0.dropFirst(6)) }
    check(Set(k).count >= 15, "G-code : valeurs de K par marche", "\(Set(k).count)")
    model.endCalibration()
    _ = await waitUntil(30, "fin de calibration") { model.calibration == nil && (model.scene?.objects.isEmpty ?? false) }
    check(model.calibration == nil && model.scene?.objects.isEmpty == true, "fin de calibration : plateau vidé")
    check(!model.overrides.isModified("before_layer_gcode"), "fin de calibration : réglages d'origine restaurés")

    print("calibration — Pressure Advance ligne / motif, débit volumétrique")
    for (label, kind, expectedLines) in [
        ("ligne", CalibrationKind.pressureAdvanceLine(start: 0, end: 0.04, step: 0.002), 21),
        ("motif", CalibrationKind.pressureAdvancePattern(start: 0, end: 0.04, step: 0.004), 11),
    ] {
        model.startCalibration(kind)
        _ = await waitUntil(60, "PA \(label)") { model.calibration != nil && model.scene?.objects.count == 1 && !model.calibrationLegend.isEmpty }
        check(model.calibrationLegend.count == expectedLines, "PA \(label) : une valeur par \(label == "ligne" ? "ligne" : "chevron")", "\(model.calibrationLegend.count)")
        if let base = model.scene?.objects.first?.instances.first {
            check(abs(base.size[0] - 25) < 0.05, "PA \(label) : base de 25 mm de large", "\(base.size)")
            check(abs(base.size[2] - 0.2) < 0.01, "PA \(label) : base d'une couche", "\(base.size[2])")
            check(!base.outside, "PA \(label) : base dans le volume d'impression")
            check(base.size[1] > 40, "PA \(label) : base assez longue pour toutes les valeurs", "\(base.size[1])")
        }
        check(model.overrides.isModified("end_gcode") && model.overrides.isModified("perimeter_generator"), "PA \(label) : G-code de fin et Arachne")
        model.slice()
        _ = await waitUntil(300, "slicing PA \(label)") { model.output != nil && !model.isSlicing && !model.resultIsStale }
        check(model.errorMessage == nil && model.output != nil, "PA \(label) : slicing", model.errorMessage ?? "")
        let text = (try? String(contentsOf: model.output!.url, encoding: .utf8)) ?? ""
        let ks = Set(text.split(separator: "\n").filter { $0.hasPrefix("M900 K") }.compactMap { Double($0.dropFirst(6)) })
        check(ks.count >= expectedLines, "PA \(label) : \(expectedLines) valeurs de K dans le G-code", "\(ks.count)")
        model.endCalibration()
        _ = await waitUntil(30, "fin PA \(label)") { model.calibration == nil && (model.scene?.objects.isEmpty ?? false) }
    }

    model.startCalibration(.maxVolumetricSpeed(start: 5, end: 12, step: 0.5))
    _ = await waitUntil(60, "débit volumétrique") { model.calibration != nil && (model.scene?.objects.first?.layerRanges.count ?? 0) > 0 }
    if let wall = model.scene?.objects.first {
        check(wall.layerRanges.count == 14, "débit volumétrique : 14 plages de hauteurs (15 valeurs)", "\(wall.layerRanges.count)")
        check(abs((wall.instances.first?.size[2] ?? 0) - 15 * 0.32) < 0.02, "débit volumétrique : mur de 15 couches de 0,32 mm", "\(String(describing: wall.instances.first?.size))")
        let speeds = wall.layerRanges.compactMap { $0.config["external_perimeter_speed"].flatMap(Double.init) }
        check(speeds.count == 14 && zip(speeds, speeds.dropFirst()).allSatisfy { $0 < $1 }, "vitesses du périmètre externe croissantes", "\(speeds)")
    }
    check(model.overrides.isModified("layer_height") && model.value(of: "layer_height") == "0.32", "hauteur de couche = 0,8 × la buse")
    model.slice()
    _ = await waitUntil(300, "slicing débit volumétrique") { model.output != nil && !model.isSlicing && !model.resultIsStale }
    check(model.errorMessage == nil && model.output != nil, "débit volumétrique : slicing", model.errorMessage ?? "")
    check(abs((model.summary?.layers ?? 0) - 15) <= 1, "débit volumétrique : ≈ 15 couches", "\(String(describing: model.summary?.layers))")
    let vsText = (try? String(contentsOf: model.output!.url, encoding: .utf8)) ?? ""
    var inExternal = false
    var feedrates = Set<Double>()
    for line in vsText.split(separator: "\n") {
        if line.hasPrefix(";TYPE:") { inExternal = line == ";TYPE:External perimeter" }
        else if inExternal, line.hasPrefix("G1 "), let f = line.split(separator: " ").first(where: { $0.hasPrefix("F") }), let v = Double(f.dropFirst()) { feedrates.insert(v) }
    }
    check(feedrates.count >= 10, "débit volumétrique : la vitesse change de couche en couche", "\(feedrates.count) vitesses")
    model.endCalibration()
    _ = await waitUntil(30, "fin débit volumétrique") { model.calibration == nil && (model.scene?.objects.isEmpty ?? false) }
    check(model.calibrationLegend.isEmpty && !model.overrides.isModified("layer_height"), "fin : réglages restaurés")

    print(failures == 0 ? "e2e: OK" : "e2e: \(failures) ÉCHEC(S)")
    return failures == 0 ? 0 : 1
}

Task { exit(await run()) }
dispatchMain()
