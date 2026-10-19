//
//  AllSettingsView.swift
//  Tous les réglages de slicing, organisés comme les onglets du bureau (Impression,
//  Filament, Imprimante → pages → groupes), avec les trois niveaux Simple / Avancé /
//  Expert, la recherche, l'aide de chaque option, l'indicateur « modifié » et le
//  retour à la valeur du preset. Les valeurs modifiées sont des surcharges du preset :
//  elles sont validées par le moteur (qsid_config_set) avant d'être utilisées.
//

import SwiftUI

struct AllSettingsView: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: ConfigMode = ConfigMode(rawValue: UserDefaults.standard.string(forKey: "qsid.settingsMode") ?? "") ?? .advanced
    @State private var tabID = "print"
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = model.settingsCatalog {
                    content(catalog)
                } else {
                    VStack(spacing: 12) { ProgressView(); Text(L10n.t("Chargement des réglages…")).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(L10n.t("Tous les réglages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.t("Terminé")) { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button(L10n.t("Tout réinitialiser"), role: .destructive) { model.overrides.resetAll() }
                            .disabled(model.overrides.isEmpty)
                        Button(L10n.t("Préparer l'export .ini…")) { model.prepareConfigExport() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel(L10n.t("Plus"))
                }
            }
            .task { await model.loadSettingsCatalog() }
        }
    }

    @ViewBuilder
    private func content(_ catalog: SettingsCatalog) -> some View {
        List {
            if let url = model.exportedConfigURL {
                Section {
                    ShareLink(item: url) {
                        Label(L10n.t("Partager la configuration effective (.ini)"), systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                } footer: {
                    Text(L10n.t("Réimportable dans QIDISlicer desktop ou ici via « Importer un profil »."))
                }
            }

            Section {
                Picker(L10n.t("Niveau"), selection: $mode) {
                    ForEach(ConfigMode.allCases) { Text(L10n.t($0.label)).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, new in UserDefaults.standard.set(new.rawValue, forKey: "qsid.settingsMode") }

                if query.isEmpty {
                    Picker(L10n.t("Onglet"), selection: $tabID) {
                        ForEach(catalog.layout.tabs) { Text(catalog.tr($0.title)).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if !query.isEmpty {
                let hits = catalog.search(query, mode: mode)
                if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section(L10n.t("Résultats")) {
                        ForEach(hits) { hit in
                            VStack(alignment: .leading, spacing: 2) {
                                OptionRow(option: hit.option, catalog: catalog)
                                Text("\(catalog.tr(hit.tab)) › \(hit.page) › \(hit.group)")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else if let tab = catalog.layout.tabs.first(where: { $0.id == tabID }) {
                Section {
                    ForEach(tab.pages) { page in
                        if !catalog.visibleGroups(of: page, mode: mode).isEmpty {
                            NavigationLink {
                                SettingsPageView(page: page, mode: mode, catalog: catalog)
                            } label: {
                                HStack {
                                    Text(catalog.tr(page.title))
                                    Spacer()
                                    let modified = modifiedCount(in: page)
                                    if modified > 0 {
                                        Text("\(modified)").font(.caption.bold()).foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(Color.orange, in: Capsule())
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                } footer: {
                    Text(L10n.t("Les valeurs modifiées s'appliquent par-dessus le profil choisi ; le point orange les signale."))
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L10n.t("Rechercher un réglage"))
    }

    private func modifiedCount(in page: SettingsLayout.Page) -> Int {
        page.groups.flatMap(\.lines).flatMap(\.keys).filter { model.overrides.isModified($0) }.count
    }
}

struct SettingsPageView: View {
    let page: SettingsLayout.Page
    let mode: ConfigMode
    let catalog: SettingsCatalog

    var body: some View {
        List {
            ForEach(Array(catalog.visibleGroups(of: page, mode: mode).enumerated()), id: \.offset) { _, entry in
                Section(catalog.tr(entry.group.title)) {
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                        ForEach(catalog.options(of: line).filter { $0.mode <= mode }) { option in
                            OptionRow(option: option, catalog: catalog,
                                      prefix: line.label.isEmpty ? nil : catalog.tr(line.label))
                        }
                    }
                }
            }
        }
        .navigationTitle(catalog.tr(page.title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Une option

/// D'où viennent et où vont les valeurs d'une ligne d'option : les réglages globaux
/// (par défaut), ou ceux d'un objet / d'un modificateur / d'une plage de couches.
struct OptionStore {
    var value: (String) -> String?
    var isModified: (String) -> Bool
    /// Valeur affichée dans « Valeur du profil : … ».
    var baseValue: (String) -> String?
    var set: (String, String) -> Void
    var reset: (String) -> Void
}

struct OptionRow: View {
    @EnvironmentObject private var model: SlicerModel
    let option: ConfigOption
    let catalog: SettingsCatalog
    var prefix: String?
    var customStore: OptionStore?

    private var store: OptionStore {
        customStore ?? OptionStore(
            value: { model.value(of: $0) },
            isModified: { model.overrides.isModified($0) },
            baseValue: { model.baseConfig[$0] },
            set: { model.setOption($0, $1) },
            reset: { model.resetOption($0) })
    }

    @State private var showHelp = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var current: String { store.value(option.key) ?? option.default ?? "" }
    private var isModified: Bool { store.isModified(option.key) }
    private var title: String {
        let label = catalog.label(option)
        if let prefix, !prefix.isEmpty, prefix != label { return "\(prefix) · \(label)" }
        return label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isModified { Circle().fill(Color.orange).frame(width: 8, height: 8) }
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                if !catalog.tooltip(option).isEmpty {
                    Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(L10n.t("Aide"))
                }
            }
            control
            if showHelp {
                Text(catalog.tooltip(option)).font(.footnote).foregroundStyle(.secondary)
            }
            if isModified {
                Button { store.reset(option.key) } label: {
                    Label(L10n.t("Valeur du profil : ") + presetValueText, systemImage: "arrow.uturn.backward")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var presetValueText: String {
        let raw = store.baseValue(option.key) ?? option.default ?? ""
        switch option.type {
        case "bool", "bools": return OptionValue.isTrue(OptionValue.first(raw)) ? L10n.t("oui") : L10n.t("non")
        case "enum", "enums": return catalog.enumLabel(option, value: OptionValue.first(raw))
        default: return raw.isEmpty ? "—" : raw
        }
    }

    // MARK: Contrôle selon le type

    @ViewBuilder
    private var control: some View {
        if option.readonly {
            Text(current).font(.callout).foregroundStyle(.secondary)
        } else {
            switch option.type {
            case "bool", "bools":
                Toggle("", isOn: Binding(
                    get: { OptionValue.isTrue(OptionValue.first(current)) },
                    set: { set($0 ? "1" : "0") }))
                    .labelsHidden()
            case "enum", "enums":
                Picker("", selection: Binding(get: { OptionValue.first(current) }, set: { set($0) })) {
                    ForEach(option.enumValues ?? [], id: \.self) { value in
                        Text(catalog.enumLabel(option, value: value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            case "int", "ints", "float", "floats", "percent", "percents", "float_or_percent", "floats_or_percents":
                numberField
            case "string":
                if option.multiline {
                    TextField("", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.system(.footnote, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onAppear { text = current }
                        .onChange(of: focused) { _, f in if !f { commitText() } }
                } else {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(commitText)
                        .onAppear { text = current }
                        .onChange(of: focused) { _, f in if !f { commitText() } }
                }
            default:
                // listes de chaînes, points : lecture seule (modifiables depuis un .ini importé)
                Text(current).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private var numberField: some View {
        HStack {
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 36)
                .focused($focused)
                .onSubmit(commitNumber)
                .onAppear { text = OptionValue.first(current) }
                .onChange(of: current) { _, new in if !focused { text = OptionValue.first(new) } }
                .onChange(of: focused) { _, f in if !f { commitNumber() } }
            if !option.sidetext.isEmpty { Text(option.sidetext).font(.callout).foregroundStyle(.secondary) }
        }
    }

    // MARK: Validation

    private func set(_ value: String) {
        store.set(option.key, option.isVector ? OptionValue.replacingFirst(of: current, with: value) : value)
    }

    private func commitText() {
        if text != current { store.set(option.key, text) }
    }

    private func commitNumber() {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard var (number, isPercent) = OptionValue.numberAndPercent(normalized) else {
            text = OptionValue.first(current); return
        }
        let wantsPercent = option.type.hasPrefix("percent")
        let integer = option.type.hasPrefix("int")
        if wantsPercent { isPercent = true }
        if integer { number = number.rounded() }
        if let lo = option.min { number = Swift.max(number, lo) }
        if let hi = option.max, !(option.type.contains("float_or_percent") && isPercent) { number = Swift.min(number, hi) }
        let formatted = OptionValue.format(number, percent: isPercent)
        text = formatted
        if formatted != OptionValue.first(current) { set(formatted) }
    }
}
