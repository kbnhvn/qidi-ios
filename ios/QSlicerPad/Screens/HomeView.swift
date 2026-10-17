//
//  HomeView.swift
//  Écran unique de la v1 : importer un modèle, choisir un profil, slicer,
//  récupérer le G-code. Pas encore de visualiseur 3D (v2 : viewport OpenGL ES
//  partagé, comme le fait déjà l'amont avec SLIC3R_OPENGL_ES).
//

import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: SlicerModel

    @State private var isImportingModel = false
    @State private var isImportingProfile = false

    private var modelTypes: [UTType] {
        var types: [UTType] = []
        if let stl = UTType(filenameExtension: "stl") { types.append(stl) }
        if let threeMF = UTType(filenameExtension: "3mf") { types.append(threeMF) }
        if let obj = UTType(filenameExtension: "obj") { types.append(obj) }
        if let amf = UTType(filenameExtension: "amf") { types.append(amf) }
        types.append(.item)
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                engineSection
                modelSection
                profileSection
                sliceSection
                if let output = model.output { resultSection(output) }
                if let error = model.errorMessage { errorSection(error) }
                aboutSection
            }
            .navigationTitle("QIDI Slice")
            .fileImporter(isPresented: $isImportingModel,
                          allowedContentTypes: modelTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importModel(from: url)
                } else if case .failure(let error) = result {
                    print("import modèle : \(error.localizedDescription)")
                }
            }
            .fileImporter(isPresented: $isImportingProfile,
                          allowedContentTypes: [.plainText, .item],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importProfile(from: url)
                } else if case .failure(let error) = result {
                    print("import profil : \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Sections

    private var engineSection: some View {
        Section {
            LabeledContent("Moteur", value: model.engineVersion)
        } footer: {
            Text("Cœur libslic3r de QIDISlicer, compilé pour arm64-iOS et exécuté dans le processus. Rien n'est envoyé sur le réseau.")
        }
    }

    private var modelSection: some View {
        Section("Modèle") {
            if let url = model.importedModel {
                LabeledContent("Fichier", value: url.lastPathComponent)
            }
            Button {
                isImportingModel = true
            } label: {
                Label(model.importedModel == nil ? "Importer un modèle…" : "Changer de modèle…",
                      systemImage: "cube.transparent")
            }
        }
    }

    private var profileSection: some View {
        Section("Profil d'impression") {
            if !model.catalog.printerModels.isEmpty {
                Picker("Imprimante", selection: $model.selectedPrinter) {
                    ForEach(model.catalog.printerModels, id: \.self) { Text($0).tag($0) }
                }
            }
            LabeledContent("Profil actif", value: model.activeProfileLabel)
            Button {
                isImportingProfile = true
            } label: {
                Label("Importer un profil QIDISlicer (.ini)…", systemImage: "doc.badge.plus")
            }
            if model.importedProfile != nil {
                Button(role: .destructive) { model.clearProfile() } label: {
                    Label("Revenir à la configuration générique", systemImage: "arrow.uturn.backward")
                }
            }
        } footer: {
            Text("Exportez votre profil depuis QIDISlicer desktop (Fichier → Exporter la configuration) et importez-le ici : c'est le même moteur, donc le même G-code. La sélection d'imprimante ci-dessus ne sert qu'à vous repérer tant que l'installation du bundle vendor n'est pas implémentée.")
        }
    }

    private var sliceSection: some View {
        Section {
            Button {
                model.slice()
            } label: {
                HStack {
                    Label("Slicer", systemImage: "scissors")
                    Spacer()
                    if model.isSlicing { ProgressView() }
                }
            }
            .disabled(model.isSlicing || model.importedModel == nil)

            if let status = model.statusLine {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func resultSection(_ output: SlicerModel.SliceOutput) -> some View {
        Section("Résultat") {
            LabeledContent("G-code", value: output.url.lastPathComponent)
            LabeledContent("Lignes", value: "\(output.lines)")
            LabeledContent("Couches", value: "\(output.layers)")
            LabeledContent("Taille", value: ByteCountFormatter.string(fromByteCount: output.sizeBytes, countStyle: .file))
            ShareLink(item: output.url) {
                Label("Partager / exporter le G-code", systemImage: "square.and.arrow.up")
            }
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
            Text("QSlicerPad est un portage iPadOS non officiel du moteur de QIDISlicer, distribué sous AGPL-3.0 — comme QIDISlicer, dont il dérive. Le code source de cette application est disponible avec l'archive du projet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("QIDISlicer (QIDI Technology)", destination: URL(string: "https://github.com/QIDITECH/QIDISlicer")!)
                .font(.footnote)
        } header: {
            Text("À propos")
        }
    }
}

#Preview {
    HomeView().environmentObject(SlicerModel())
}
