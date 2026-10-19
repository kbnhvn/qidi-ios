//
//  SettingsView.swift
//  Réglages : imprimante Moonraker, profils par défaut, langue, à propos.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss

    @State private var language: String = L10n.language

    var body: some View {
        NavigationStack {
            Form {
                printerSection
                languageSection
                aboutSection
            }
            .navigationTitle(L10n.t("Réglages"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Terminé")) { dismiss() }
                }
            }
            .onChange(of: language) { _, newValue in
                L10n.language = newValue
                model.languageVersion += 1
                model.refreshLanguage()
            }
        }
    }

    // MARK: Sections

    private var printerSection: some View {
        Section {
            TextField(L10n.t("Ex. 192.168.1.42 ou qidi.local"), text: $model.moonraker.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField(L10n.t("Port"), value: $model.moonraker.port, format: .number)
                .keyboardType(.numberPad)
            SecureField(L10n.t("Clé API (facultatif)"), text: $model.moonraker.apiKey)
            Button(L10n.t("Tester la connexion")) {
                model.refreshPrinterStatus()
            }
            .disabled(!model.moonraker.isConfigured)
            if let status = model.printerStatus {
                Text("\(L10n.t(status.stateLabel))" + (status.nozzle.map { String(format: " · %.0f °C", $0) } ?? ""))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let error = model.printerError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text(L10n.t("Imprimante (Moonraker)"))
        } footer: {
            Text(L10n.t("L'app contacte directement l'imprimante sur le réseau local (Moonraker). Rien ne transite par un serveur."))
        }
    }

    private var languageSection: some View {
        Section(L10n.t("Langue")) {
            Picker(L10n.t("Langue"), selection: $language) {
                Text(L10n.t("Système")).tag("system")
                Text(L10n.t("Français")).tag("fr")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
        }
    }

    private var aboutSection: some View {
        Section(L10n.t("À propos")) {
            LabeledContent(L10n.t("Version du moteur"), value: model.engineVersion)
            LabeledContent(L10n.t("Licence"), value: "AGPL-3.0")
            Link("QIDISlicer (QIDI Technology)",
                 destination: URL(string: "https://github.com/QIDITECH/QIDISlicer")!)
            Text(L10n.t("QSlicerPad est un portage iPadOS non officiel du moteur de QIDISlicer, distribué sous AGPL-3.0 — comme QIDISlicer, dont il dérive. Le code source de cette application est disponible avec l'archive du projet."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView().environmentObject(SlicerModel())
}
