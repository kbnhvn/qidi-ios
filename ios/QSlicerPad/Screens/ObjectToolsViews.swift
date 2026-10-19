//
//  ObjectToolsViews.swift
//  Outils d'objet : panneau de coupe (le plan s'affiche sur le plateau), simplification
//  du maillage, réglages par objet / modificateurs / plages de hauteurs.
//

import SwiftUI

// MARK: - Coupe

/// Panneau flottant de l'outil de coupe.
struct CutPanel: View {
    @EnvironmentObject private var model: SlicerModel
    @State private var keep: CutPlane.Keep = .both
    @State private var placeOnCut = true

    var body: some View {
        if let plane = model.cutPlane,
           let object = model.scene?.objects.first(where: { $0.id == plane.objectID }),
           let instance = object.instances.first,
           let range = CutPlane.range(of: instance, axis: plane.axis) {
            let halves = plane.halves(of: instance)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.t("Couper"), systemImage: "scissors").font(.headline)
                    Spacer()
                    Button(L10n.t("Annuler")) { model.cancelCut() }
                }
                Picker(L10n.t("Plan"), selection: Binding(get: { plane.axis }, set: { model.setCutAxis($0) })) {
                    Text(L10n.t("Horizontal (Z)")).tag(CutPlane.Axis.z)
                    Text(L10n.t("Vertical (X)")).tag(CutPlane.Axis.x)
                    Text(L10n.t("Vertical (Y)")).tag(CutPlane.Axis.y)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { plane.position },
                        set: { model.cutPlane?.position = Swift.min(Swift.max($0, range.lowerBound), range.upperBound) }),
                        in: range)
                    NumberField(label: plane.axis.rawValue.uppercased(), value: plane.position, decimals: 2) {
                        model.cutPlane?.position = Swift.min(Swift.max($0, range.lowerBound), range.upperBound)
                    }
                    .frame(width: 130)
                }

                Text(String(format: L10n.t("Moitiés : %.1f mm et %.1f mm"), halves.lower, halves.upper))
                    .font(.footnote).foregroundStyle(.secondary)

                Picker(L10n.t("Garder"), selection: $keep) {
                    Text(L10n.t("Les deux")).tag(CutPlane.Keep.both)
                    Text(plane.axis == .z ? L10n.t("Dessus") : L10n.t("Côté +")).tag(CutPlane.Keep.upper)
                    Text(plane.axis == .z ? L10n.t("Dessous") : L10n.t("Côté −")).tag(CutPlane.Keep.lower)
                }
                .pickerStyle(.segmented)
                Toggle(L10n.t("Poser la face coupée à plat"), isOn: $placeOnCut)

                Button { model.applyCut(keep: keep, placeOnCut: placeOnCut) } label: {
                    Label(L10n.t("Couper"), systemImage: "scissors").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - Simplification

struct SimplifySheet: View {
    let objectID: UInt64
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss
    @State private var ratio = 0.5

    var body: some View {
        NavigationStack {
            if let object = model.scene?.objects.first(where: { $0.id == objectID }) {
                Form {
                    Section {
                        LabeledContent(L10n.t("Triangles actuels"), value: "\(object.triangles)")
                        Slider(value: $ratio, in: 0.05...0.95, step: 0.05) {
                            Text(L10n.t("Conserver"))
                        }
                        LabeledContent(L10n.t("Conserver"), value: "\(Int(ratio * 100)) % → ≈ \(Int(Double(object.triangles) * ratio))")
                    } footer: {
                        Text(L10n.t("Réduit le nombre de triangles d'un maillage très dense (scans, sculpts) pour accélérer le découpage. Les détails fins peuvent être perdus."))
                    }
                    Section {
                        Button {
                            model.simplify(objectID: objectID, ratio: ratio)
                            dismiss()
                        } label: {
                            Label(L10n.t("Simplifier"), systemImage: "square.3.layers.3d.down.right").frame(minHeight: 44)
                        }
                        .disabled(object.triangles < 100)
                    }
                }
                .navigationTitle(L10n.t("Simplifier le maillage"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Annuler")) { dismiss() } } }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Réglages par objet

struct ObjectSettingsView: View {
    let objectID: UInt64
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickerTarget: PickerTarget?

    enum PickerTarget: Identifiable, Equatable {
        case object
        case modifier(UInt64)
        case range(Double, Double)
        var id: String {
            switch self {
            case .object: return "object"
            case .modifier(let v): return "modifier-\(v)"
            case .range(let a, let b): return "range-\(a)-\(b)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let object = model.scene?.objects.first(where: { $0.id == objectID }),
                   let catalog = model.settingsCatalog {
                    content(object, catalog)
                } else {
                    VStack(spacing: 12) { ProgressView(); Text(L10n.t("Chargement des réglages…")).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(L10n.t("Réglages de l'objet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("Terminé")) { dismiss() } } }
            .task { await model.loadSettingsCatalog() }
            .sheet(item: $pickerTarget) { target in
                if let catalog = model.settingsCatalog {
                    ObjectOptionPicker(catalog: catalog, existing: existingKeys(for: target)) { key in
                        add(key, to: target, catalog: catalog)
                    }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ object: SceneObject, _ catalog: SettingsCatalog) -> some View {
        List {
            if model.isMultiFilament {
                Section {
                    let colors = model.filamentColors
                    Picker(L10n.t("Filament"), selection: Binding(
                        get: { Int(object.config["extruder"] ?? "1") ?? 1 },
                        set: { model.setObjectOption("extruder", "\($0)", objectID: object.id) })) {
                        ForEach(1...model.extruderCount, id: \.self) { n in
                            Label {
                                Text("T\(n) · " + ((n - 1) < model.extruderFilaments.count
                                    ? (model.extruderFilaments[n - 1].components(separatedBy: " @").first ?? "") : ""))
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Color(hex: (n - 1) < colors.count ? colors[n - 1] : "#999999"))
                            }
                            .tag(n)
                        }
                    }
                    .frame(minHeight: 44)
                } footer: {
                    Text(L10n.t("Le filament (outil) avec lequel cet objet est imprimé."))
                }
            }

            Section {
                ForEach(object.config.keys.sorted().filter { $0 != "extruder" }, id: \.self) { key in
                    if let option = catalog.options[key] {
                        OptionRow(option: option, catalog: catalog, customStore: store(object: object, volume: nil))
                    }
                }
                addMenu(existing: Set(object.config.keys), catalog: catalog, target: .object)
                if !object.config.isEmpty {
                    Button(role: .destructive) { model.resetObjectOption(nil, objectID: object.id) } label: {
                        Label(L10n.t("Retirer tous les réglages de l'objet"), systemImage: "arrow.uturn.backward").frame(minHeight: 44)
                    }
                }
            } header: {
                Text("\(L10n.t("Objet")) · \(object.name)")
            } footer: {
                Text(L10n.t("Ces réglages remplacent ceux du profil pour cet objet seulement."))
            }

            Section {
                ForEach(object.modifiers) { volume in
                    ModifierEditor(object: object, volume: volume, catalog: catalog,
                                   store: store(object: object, volume: volume)) { target in pickerTarget = target }
                }
                Menu {
                    ForEach(ObjectSettings.ModifierKind.allCases) { kind in
                        Menu(kindTitle(kind)) {
                            ForEach(ObjectSettings.ModifierShape.allCases) { shape in
                                Button { model.addModifier(objectID: object.id, shape: shape, kind: kind) } label: {
                                    Label(shapeTitle(shape), systemImage: shape.symbol)
                                }
                            }
                        }
                    }
                } label: {
                    Label(L10n.t("Ajouter un modificateur"), systemImage: "plus.circle").frame(minHeight: 44)
                }
            } header: {
                Text(L10n.t("Modificateurs"))
            } footer: {
                Text(L10n.t("Un volume qui change les réglages (ou bloque / force les supports) dans sa zone seulement."))
            }

            Section {
                ForEach(object.layerRanges) { range in
                    RangeEditor(object: object, range: range, catalog: catalog,
                                store: store(object: object, range: range)) { target in pickerTarget = target }
                }
                Button { model.addLayerRange(objectID: object.id) } label: {
                    Label(L10n.t("Ajouter une plage de hauteurs"), systemImage: "plus.circle").frame(minHeight: 44)
                }
            } header: {
                Text(L10n.t("Plages de hauteurs"))
            } footer: {
                Text(L10n.t("Réglages différents entre deux hauteurs Z de l'objet (par exemple des couches plus fines en haut)."))
            }
        }
    }

    private func addMenu(existing: Set<String>, catalog: SettingsCatalog, target: PickerTarget) -> some View {
        Menu {
            ForEach(ObjectSettings.quickKeys.filter { !existing.contains($0) }, id: \.self) { key in
                if let option = catalog.options[key], option.isPerObject {
                    Button(catalog.label(option)) { add(key, to: target, catalog: catalog) }
                }
            }
            Button(L10n.t("Autres réglages…")) { pickerTarget = target }
        } label: {
            Label(L10n.t("Ajouter un réglage"), systemImage: "plus.circle").frame(minHeight: 44)
        }
    }

    // MARK: Ajout d'un réglage

    private func existingKeys(for target: PickerTarget) -> Set<String> {
        guard let object = model.scene?.objects.first(where: { $0.id == objectID }) else { return [] }
        switch target {
        case .object: return Set(object.config.keys)
        case .modifier(let id): return Set(object.volumes.first(where: { $0.id == id })?.config.keys.map { $0 } ?? [])
        case .range(let lo, let hi):
            return Set(object.layerRanges.first(where: { $0.min == lo && $0.max == hi })?.config.keys.map { $0 } ?? [])
        }
    }

    /// Le nouveau réglage démarre à la valeur actuelle (celle du profil), prête à être modifiée.
    private func add(_ key: String, to target: PickerTarget, catalog: SettingsCatalog) {
        let initial = model.value(of: key) ?? catalog.options[key]?.default ?? ""
        switch target {
        case .object: model.setObjectOption(key, initial, objectID: objectID)
        case .modifier(let id): model.setObjectOption(key, initial, objectID: objectID, volumeID: id)
        case .range(let lo, let hi): model.setLayerRangeOption(objectID: objectID, minZ: lo, maxZ: hi, key: key, value: initial)
        }
    }

    // MARK: Accès aux valeurs

    private func store(object: SceneObject, volume: SceneVolume?) -> OptionStore {
        let id = object.id, vid = volume?.id ?? 0
        return OptionStore(
            value: { model.objectValue(of: $0, objectID: id, volumeID: vid) },
            isModified: { model.isObjectOptionModified($0, objectID: id, volumeID: vid) },
            baseValue: { key in
                // « valeur du profil » d'un modificateur : celle de l'objet si elle existe
                (vid != 0 ? object.config[key] : nil) ?? model.baseConfig[key]
            },
            set: { model.setObjectOption($0, $1, objectID: id, volumeID: vid) },
            reset: { model.resetObjectOption($0, objectID: id, volumeID: vid) })
    }

    private func store(object: SceneObject, range: SceneLayerRange) -> OptionStore {
        let id = object.id
        return OptionStore(
            value: { range.config[$0] ?? object.config[$0] ?? model.value(of: $0) },
            isModified: { range.config[$0] != nil },
            baseValue: { object.config[$0] ?? model.baseConfig[$0] },
            set: { model.setLayerRangeOption(objectID: id, minZ: range.min, maxZ: range.max, key: $0, value: $1) },
            reset: { model.removeLayerRange(objectID: id, minZ: range.min, maxZ: range.max, key: $0) })
    }

    private func kindTitle(_ kind: ObjectSettings.ModifierKind) -> String {
        switch kind {
        case .modifier: return L10n.t("Modificateur de réglages")
        case .supportBlocker: return L10n.t("Bloqueur de supports")
        case .supportEnforcer: return L10n.t("Forceur de supports")
        }
    }

    private func shapeTitle(_ shape: ObjectSettings.ModifierShape) -> String {
        switch shape {
        case .box: return L10n.t("Boîte")
        case .cylinder: return L10n.t("Cylindre")
        case .sphere: return L10n.t("Sphère")
        }
    }
}

/// Un modificateur : forme, position, taille et ses réglages.
private struct ModifierEditor: View {
    let object: SceneObject
    let volume: SceneVolume
    let catalog: SettingsCatalog
    let store: OptionStore
    let pick: (ObjectSettingsView.PickerTarget) -> Void
    @EnvironmentObject private var model: SlicerModel

    private var title: String {
        switch volume.kind {
        case "blocker": return L10n.t("Bloqueur de supports")
        case "enforcer": return L10n.t("Forceur de supports")
        default: return L10n.t("Modificateur")
        }
    }

    private var center: [Double] {
        guard let inst = object.instances.first else { return volume.offset }
        return ObjectSettings.worldCenter(local: volume.offset, matrix: inst.matrix)
    }

    var body: some View {
        DisclosureGroup {
            axisRow(L10n.t("Position (mm)"), values: center, decimals: 1) { axis, value in
                var c = center; c[axis] = value
                model.updateModifier(objectID: object.id, volumeID: volume.id, centerWorld: c, size: nil)
            }
            axisRow(L10n.t("Taille (mm)"), values: volume.size, decimals: 1) { axis, value in
                guard value > 0.1 else { return }
                var s = volume.size; s[axis] = value
                model.updateModifier(objectID: object.id, volumeID: volume.id, centerWorld: nil, size: s)
            }
            if volume.kind == "modifier" {
                ForEach(volume.config.keys.sorted(), id: \.self) { key in
                    if let option = catalog.options[key] {
                        OptionRow(option: option, catalog: catalog, customStore: store)
                    }
                }
                Menu {
                    ForEach(ObjectSettings.quickKeys.filter { volume.config[$0] == nil }, id: \.self) { key in
                        if let option = catalog.options[key], option.isPerObject {
                            Button(catalog.label(option)) {
                                model.setObjectOption(key, model.value(of: key) ?? option.default ?? "",
                                                      objectID: object.id, volumeID: volume.id)
                            }
                        }
                    }
                    Button(L10n.t("Autres réglages…")) { pick(.modifier(volume.id)) }
                } label: {
                    Label(L10n.t("Ajouter un réglage"), systemImage: "plus.circle").frame(minHeight: 44)
                }
            }
            Button(role: .destructive) { model.removeModifier(objectID: object.id, volumeID: volume.id) } label: {
                Label(L10n.t("Supprimer"), systemImage: "trash").frame(minHeight: 44)
            }
        } label: {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint)
                Text("\(title) · \(L10n.t(volume.name.capitalized))")
                if volume.kind == "modifier", !volume.config.isEmpty {
                    Text("\(volume.config.count)").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.orange, in: Capsule())
                }
            }
            .frame(minHeight: 44)
        }
    }

    private var symbol: String {
        ObjectSettings.ModifierShape(rawValue: volume.name)?.symbol ?? "cube"
    }

    private var tint: Color {
        switch volume.kind {
        case "blocker": return .red
        case "enforcer": return .green
        default: return .blue
        }
    }

    private func axisRow(_ title: String, values: [Double], decimals: Int,
                         commit: @escaping (Int, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { axis in
                    NumberField(label: ["X", "Y", "Z"][axis], value: values[axis], decimals: decimals) { commit(axis, $0) }
                }
            }
        }
    }
}

/// Une plage de hauteurs et ses réglages.
private struct RangeEditor: View {
    let object: SceneObject
    let range: SceneLayerRange
    let catalog: SettingsCatalog
    let store: OptionStore
    let pick: (ObjectSettingsView.PickerTarget) -> Void
    @EnvironmentObject private var model: SlicerModel

    var body: some View {
        DisclosureGroup {
            HStack(spacing: 8) {
                NumberField(label: "Z min", value: range.min, decimals: 2) { v in
                    model.moveLayerRange(objectID: object.id, from: range, minZ: v, maxZ: range.max)
                }
                NumberField(label: "Z max", value: range.max, decimals: 2) { v in
                    model.moveLayerRange(objectID: object.id, from: range, minZ: range.min, maxZ: v)
                }
            }
            // « extruder » est un champ technique que le moteur ajoute à chaque plage
            ForEach(range.config.keys.sorted().filter { $0 != "extruder" }, id: \.self) { key in
                if let option = catalog.options[key] {
                    OptionRow(option: option, catalog: catalog, customStore: store)
                }
            }
            Menu {
                ForEach(ObjectSettings.quickKeys.filter { range.config[$0] == nil }, id: \.self) { key in
                    if let option = catalog.options[key], option.isPerObject {
                        Button(catalog.label(option)) {
                            model.setLayerRangeOption(objectID: object.id, minZ: range.min, maxZ: range.max, key: key,
                                                      value: model.value(of: key) ?? option.default ?? "")
                        }
                    }
                }
                Button(L10n.t("Autres réglages…")) { pick(.range(range.min, range.max)) }
            } label: {
                Label(L10n.t("Ajouter un réglage"), systemImage: "plus.circle").frame(minHeight: 44)
            }
            Button(role: .destructive) {
                model.removeLayerRange(objectID: object.id, minZ: range.min, maxZ: range.max)
            } label: {
                Label(L10n.t("Supprimer la plage"), systemImage: "trash").frame(minHeight: 44)
            }
        } label: {
            Label(String(format: "%.1f – %.1f mm", range.min, range.max), systemImage: "line.3.horizontal.decrease")
                .frame(minHeight: 44)
        }
    }
}

/// Choix d'un réglage parmi toutes les options applicables à un objet.
struct ObjectOptionPicker: View {
    let catalog: SettingsCatalog
    let existing: Set<String>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [ConfigOption] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return catalog.options.values
            .filter { $0.isPerObject && !$0.readonly && !existing.contains($0.key) }
            .filter { option in
                let haystack = (catalog.label(option) + " " + option.key).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .sorted { catalog.label($0).localizedCaseInsensitiveCompare(catalog.label($1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { option in
                Button {
                    onPick(option.key)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(catalog.label(option)).foregroundStyle(.primary)
                        Text(option.key).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.t("Rechercher un réglage"))
            .navigationTitle(L10n.t("Ajouter un réglage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Annuler")) { dismiss() } } }
        }
    }
}
