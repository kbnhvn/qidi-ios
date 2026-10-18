//
//  PadHomeView.swift
//  Disposition iPad : deux colonnes.
//    - barre latérale : profils, imprimante, à propos
//    - détail : modèle, slicing, résultat
//  Optimisée tactile : cibles ≥ 44 pt, actions principales larges, drag & drop,
//  raccourcis clavier, retours haptiques.
//

import SwiftUI
import UniformTypeIdentifiers

struct PadHomeView: View {
    @EnvironmentObject private var model: SlicerModel

    @State private var isImportingModel = false
    @State private var isImportingProfile = false
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                ProfileSection(model: model, isImportingProfile: $isImportingProfile)
                PrinterSection(model: model)
                AboutSection()
            }
            .navigationTitle("QIDI Slice")
            .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L10n.t("Réglages"))
                        .keyboardShortcut(",", modifiers: [.command])
                }
            }
        } detail: {
            List {
                EngineSection(model: model)
                ModelSection(model: model, isImportingModel: $isImportingModel)
                SliceSection(model: model)
                if let output = model.output {
                    ResultSection(model: model, output: output)
                }
                if let error = model.errorMessage { ErrorSection(message: error) }
            }
            .navigationTitle(model.importedModel?.lastPathComponent ?? L10n.t("Modèle"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { isImportingModel = true } label: {
                        Label(L10n.t("Importer un modèle…"), systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .modifier(DocumentImportModifiers(isImportingModel: $isImportingModel,
                                          isImportingProfile: $isImportingProfile))
        // Déposer un fichier depuis Fichiers, Shapr3D, AirDrop… agit comme un import.
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDroppedFiles(urls)
        }
        .sensoryFeedback(.success, trigger: model.successTick)
        .sensoryFeedback(.error, trigger: model.errorTick)
    }
}
