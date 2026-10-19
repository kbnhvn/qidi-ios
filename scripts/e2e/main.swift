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
    model.saveUserPreset(named: "Mon essai")
    check(model.userPresets.keys.contains("Mon essai"), "préréglage enregistré")
    model.overrides.resetAll()
    check(model.overrides.isEmpty, "réglages remis au preset")
    model.applyUserPreset("Mon essai")
    check(model.overrides.supportMode(base: model.baseConfig) == .buildPlateOnly, "préréglage rappelé")
    model.deleteUserPreset("Mon essai")
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

    print(failures == 0 ? "e2e: OK" : "e2e: \(failures) ÉCHEC(S)")
    return failures == 0 ? 0 : 1
}

Task { exit(await run()) }
dispatchMain()
