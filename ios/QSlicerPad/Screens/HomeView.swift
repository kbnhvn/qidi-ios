//
//  HomeView.swift
//  Écran principal : profil (bundle QIDI ou .ini importé), modèle, slicing avec
//  progression/annulation, aperçu et envoi à l'imprimante.
//

import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: SlicerModel

    @State private var isImportingModel = false
    @State private var isImportingProfile = false
    @State private var showSettings = false

    private var modelTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["stl", "3mf", "obj", "amf"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.item)
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                engineSection
                profileSection
                modelSection
                sliceSection
                if let output = model.output {
                    resultSection(output)
                    printerSection
                }
                if let error = model.errorMessage { errorSection(error) }
                aboutSection
            }
            .navigationTitle("QIDI Slice")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L10n.t("Réglages"))
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .fileImporter(isPresented: $isImportingModel,
                          allowedContentTypes: modelTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importModel(from: url)
                }
            }
            .fileImporter(isPresented: $isImportingProfile,
                          allowedContentTypes: [.plainText, .item],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importProfile(from: url)
                }
            }
        }
    }

    // MARK: Sections

    private var engineSection: some View {
        Section {
            LabeledContent(L10n.t("Moteur"), value: model.engineVersion)
        } footer: {
            Text(L10n.t("Cœur libslic3r de QIDISlicer, compilé pour arm64-iOS et exécuté dans le processus. Le slicing est local ; seule l'imprimante que vous configurez est contactée."))
        }
    }

    private var profileSection: some View {
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
            }
            LabeledContent(L10n.t("Profil actif"), value: model.activeProfileLabel)
            Button {
                isImportingProfile = true
            } label: {
                Label(L10n.t("Importer un profil QIDISlicer (.ini)…"), systemImage: "doc.badge.plus")
            }
            if model.importedProfile != nil {
                Button(role: .destructive) { model.clearProfile() } label: {
                    Label(L10n.t("Revenir aux profils embarqués"), systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text(L10n.t("Profil d'impression"))
        } footer: {
            Text(L10n.t("Les profils QIDI sont embarqués : choisissez imprimante, réglages et filament. Un .ini exporté de QIDISlicer desktop reste possible (il a alors priorité) — c'est le même moteur, donc le même G-code."))
        }
    }

    private var modelSection: some View {
        Section(L10n.t("Modèle")) {
            if let url = model.importedModel {
                LabeledContent(L10n.t("Fichier"), value: url.lastPathComponent)
                if let mesh = model.mesh {
                    NavigationLink {
                        ViewerScreen(content: .model(mesh))
                            .navigationTitle(L10n.t("Modèle"))
                    } label: {
                        Label(L10n.t("Voir en 3D"), systemImage: "cube.transparent")
                    }
                }
            }
            Button {
                isImportingModel = true
            } label: {
                Label(L10n.t(model.importedModel == nil ? "Importer un modèle…" : "Changer de modèle…"),
                      systemImage: "square.and.arrow.down")
            }
        }
    }

    private var sliceSection: some View {
        Section {
            Button {
                model.slice()
            } label: {
                HStack {
                    Label(L10n.t("Slicer"), systemImage: "scissors")
                    Spacer()
                    if model.isSlicing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.isSlicing || model.importedModel == nil)

            if model.isSlicing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.progress)
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
                    }
                }
            }

            if let status = model.statusLine {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.t("Le slicing se fait sur l'iPad, dans le processus de l'app : progression et annulation comprises."))
        }
    }

    private func resultSection(_ output: SlicerModel.SliceOutput) -> some View {
        Section(L10n.t("Résultat")) {
            LabeledContent("G-code", value: output.url.lastPathComponent)
            LabeledContent(L10n.t("Lignes"), value: "\(output.lines)")
            LabeledContent(L10n.t("Couches"), value: "\(output.layers)")
            LabeledContent(L10n.t("Taille"), value: ByteCountFormatter.string(fromByteCount: output.sizeBytes, countStyle: .file))
            LabeledContent(L10n.t("Durée"), value: String(format: "%.1f s", output.seconds))
            if let preview = model.preview {
                NavigationLink {
                    ViewerScreen(content: .gcode(preview))
                        .navigationTitle(L10n.t("Aperçu G-code"))
                } label: {
                    Label(L10n.t("Aperçu G-code"), systemImage: "square.stack.3d.up")
                }
            }
            ShareLink(item: output.url) {
                Label(L10n.t("Partager / exporter le G-code"), systemImage: "square.and.arrow.up")
            }
        }
    }

    private var printerSection: some View {
        Section(L10n.t("Imprimante")) {
            LabeledContent(L10n.t("Adresse"), value: model.moonraker.isConfigured
                           ? "\(model.moonraker.host):\(model.moonraker.port)"
                           : L10n.t("non configurée"))
            Button {
                model.uploadAndPrint()
            } label: {
                HStack {
                    Label(L10n.t("Envoyer et lancer l'impression"), systemImage: "paperplane")
                    Spacer()
                    if model.isUploading { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.isUploading || !model.moonraker.isConfigured)

            if let status = model.uploadStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Button(L10n.t("Actualiser l'état")) { model.refreshPrinterStatus() }
                .font(.footnote)
                .disabled(!model.moonraker.isConfigured)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var aboutSection: some View {
        Section {
            Text(L10n.t("QSlicerPad est un portage iPadOS non officiel du moteur de QIDISlicer, distribué sous AGPL-3.0 — comme QIDISlicer, dont il dérive. Le code source de cette application est disponible avec l'archive du projet."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("QIDISlicer (QIDI Technology)", destination: URL(string: "https://github.com/QIDITECH/QIDISlicer")!)
                .font(.footnote)
        } header: {
            Text(L10n.t("À propos"))
        }
    }
}

#Preview {
    HomeView().environmentObject(SlicerModel())
}
