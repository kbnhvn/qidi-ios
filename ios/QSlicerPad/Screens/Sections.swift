//
//  Sections.swift
//  Sections partagées entre la disposition iPad (deux colonnes) et iPhone.
//
//  Ce sont de vraies Views (et non des fonctions) : elles ont besoin des bindings
//  du modèle (`$model.selectedPrinter`) via @ObservedObject, et une Section insérée
//  dans un List se comporte comme n'importe quelle vue.
//

import SwiftUI

struct EngineSection: View {
    @ObservedObject var model: SlicerModel

    var body: some View {
        Section {
            LabeledContent(L10n.t("Moteur"), value: model.engineVersion)
        } footer: {
            Text(L10n.t("Cœur libslic3r de QIDISlicer, compilé pour arm64-iOS et exécuté dans le processus. Le slicing est local ; seule l'imprimante que vous configurez est contactée."))
        }
    }
}

struct ProfileSection: View {
    @ObservedObject var model: SlicerModel
    @Binding var isImportingProfile: Bool

    @State private var showSliceSettings = false

    var body: some View {
        Section {
            if model.hasEmbeddedProfiles {
                Picker(L10n.t("Imprimante"), selection: $model.selectedPrinter) {
                    ForEach(model.catalog.printers, id: \.self) { Text($0).tag($0) }
                }
                Picker(L10n.t("Réglages d'impression"), selection: $model.selectedPrint) {
                    ForEach(model.catalog.printPresets(for: model.selectedPrinter), id: \.self) { Text($0).tag($0) }
                }
                let filaments = model.catalog.filamentPresets(for: model.selectedPrinter)
                if !filaments.isEmpty {
                    Picker(L10n.t("Filament"), selection: $model.selectedFilament) {
                        Text(L10n.t("—")).tag("")
                        ForEach(filaments, id: \.self) { Text($0).tag($0) }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.t("Aucun profil embarqué"), systemImage: "shippingbox")
                } description: {
                    Text(L10n.t("Importez un profil .ini exporté depuis QIDISlicer desktop."))
                }
            }

            LabeledContent(L10n.t("Profil actif"), value: model.activeProfileLabel)

            // Accès direct aux réglages de slicing (supports, adhérence, remplissage…).
            Button { showSliceSettings = true } label: {
                HStack {
                    Label(L10n.t("Options de slicing…"), systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
            }
            .sheet(isPresented: $showSliceSettings) {
                SliceSettingsView().environmentObject(model)
            }

            if let summary = model.overrides.summary(base: model.presetConfig) {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }

            Button {
                isImportingProfile = true
            } label: {
                Label(L10n.t("Importer un profil QIDISlicer (.ini)…"), systemImage: "doc.badge.plus")
                    .frame(minHeight: 44)   // cible tactile confortable
            }

            if model.importedProfile != nil {
                Button(role: .destructive) { model.clearProfile() } label: {
                    Label(L10n.t("Revenir aux profils embarqués"), systemImage: "arrow.uturn.backward")
                        .frame(minHeight: 44)
                }
            }
        } header: {
            Text(L10n.t("Profil d'impression"))
        } footer: {
            Text(L10n.t("Les profils QIDI sont embarqués : choisissez imprimante, réglages et filament. Un .ini exporté de QIDISlicer desktop reste possible (il a alors priorité) — c'est le même moteur, donc le même G-code."))
        }
    }
}

struct ModelSection: View {
    @ObservedObject var model: SlicerModel
    @Binding var isImportingModel: Bool

    /// Le visualiseur s'ouvre en feuille : pas de navigation poussée dont on ne
    /// peut plus revenir (bouton « Terminé » toujours présent).
    @State private var showViewer = false

    var body: some View {
        Section(L10n.t("Modèle")) {
            if let url = model.importedModel {
                LabeledContent(L10n.t("Fichier"), value: url.lastPathComponent)
                if model.mesh != nil {
                    Button { showViewer = true } label: {
                        Label(L10n.t("Voir en 3D"), systemImage: "cube.transparent")
                            .frame(minHeight: 44)
                    }
                    .sheet(isPresented: $showViewer) {
                        if let mesh = model.mesh {
                            NavigationStack { ViewerScreen(content: .model(mesh)) }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.t("Aucun modèle"), systemImage: "cube")
                } description: {
                    Text(L10n.t("Importez un STL, 3MF, OBJ ou AMF — ou déposez le fichier dans l'app."))
                }
            }

            Button {
                isImportingModel = true
            } label: {
                Label(L10n.t(model.importedModel == nil ? "Importer un modèle…" : "Changer de modèle…"),
                      systemImage: "square.and.arrow.down")
                    .frame(minHeight: 44)
            }
        }
    }
}

struct SliceSection: View {
    @ObservedObject var model: SlicerModel

    var body: some View {
        Section {
            Button {
                model.slice()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "scissors")
                    Text(L10n.t("Slicer")).font(.headline)
                    Spacer()
                    if model.isSlicing { ProgressView().controlSize(.regular) }
                }
                .frame(maxWidth: .infinity, minHeight: 52)   // grosse cible tactile
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSlicing || model.importedModel == nil)
            .keyboardShortcut(.return, modifiers: [.command])

            if model.isSlicing {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: model.progress)
                        .controlSize(.large)
                    HStack {
                        Text(model.progressText.isEmpty ? L10n.t("Slicing…") : model.progressText)
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(model.progress * 100)) %")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { model.cancel() } label: {
                        Label(L10n.t("Annuler"), systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }

            if let status = model.statusLine {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.t("Le slicing se fait sur l'iPad, dans le processus de l'app : progression et annulation comprises."))
        }
    }
}

struct ResultSection: View {
    @ObservedObject var model: SlicerModel
    let output: SlicerModel.SliceOutput

    @State private var showPreview = false

    var body: some View {
        Section(L10n.t("Résultat")) {
            LabeledContent("G-code", value: output.url.lastPathComponent)
            LabeledContent(L10n.t("Lignes"), value: "\(output.lines)")
            LabeledContent(L10n.t("Couches"), value: "\(output.layers)")
            LabeledContent(L10n.t("Taille"), value: ByteCountFormatter.string(fromByteCount: output.sizeBytes, countStyle: .file))
            LabeledContent(L10n.t("Durée"), value: String(format: "%.1f s", output.seconds))

            if model.preview != nil {
                Button { showPreview = true } label: {
                    Label(L10n.t("Aperçu G-code"), systemImage: "square.stack.3d.up")
                        .frame(minHeight: 44)
                }
                .sheet(isPresented: $showPreview) {
                    if let preview = model.preview {
                        NavigationStack { ViewerScreen(content: .gcode(preview)) }
                    }
                }
            }
            ShareLink(item: output.url) {
                Label(L10n.t("Partager / exporter le G-code"), systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
        }
    }
}

struct PrinterSection: View {
    @ObservedObject var model: SlicerModel

    var body: some View {
        Section(L10n.t("Imprimante")) {
            LabeledContent(L10n.t("Adresse"), value: model.moonraker.isConfigured
                           ? "\(model.moonraker.host):\(model.moonraker.port)"
                           : L10n.t("non configurée"))

            Button {
                model.uploadAndPrint()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane")
                    Text(L10n.t("Envoyer et lancer l'impression")).font(.headline)
                    Spacer()
                    if model.isUploading { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(model.isUploading || !model.moonraker.isConfigured)

            if let status = model.uploadStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Button(L10n.t("Actualiser l'état")) { model.refreshPrinterStatus() }
                .frame(minHeight: 44)
                .disabled(!model.moonraker.isConfigured)
        }
    }
}

struct ErrorSection: View {
    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

struct AboutSection: View {
    var body: some View {
        Section {
            Text(L10n.t("QSlicerPad est un portage iPadOS non officiel du moteur de QIDISlicer, distribué sous AGPL-3.0 — comme QIDISlicer, dont il dérive. Le code source de cette application est disponible avec l'archive du projet."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("QIDISlicer (QIDI Technology)",
                 destination: URL(string: "https://github.com/QIDITECH/QIDISlicer")!)
                .font(.footnote)
                .frame(minHeight: 44)
        } header: {
            Text(L10n.t("À propos"))
        }
    }
}
