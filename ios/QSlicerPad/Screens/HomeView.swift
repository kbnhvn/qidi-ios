//
//  HomeView.swift
//  Disposition compacte (iPhone, Split View étroite) : une seule colonne.
//  La variante iPad (deux colonnes) est dans PadHomeView.
//

import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: SlicerModel

    @State private var isImportingModel = false
    @State private var isImportingProfile = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                EngineSection(model: model)
                ProfileSection(model: model, isImportingProfile: $isImportingProfile)
                ModelSection(model: model, isImportingModel: $isImportingModel)
                SliceSection(model: model)
                if let output = model.output {
                    ResultSection(model: model, output: output)
                    PrinterSection(model: model)
                }
                if let error = model.errorMessage { ErrorSection(message: error) }
                AboutSection()
            }
            .navigationTitle("QIDI Slice")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L10n.t("Réglages"))
                        .keyboardShortcut(",", modifiers: [.command])
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .modifier(DocumentImportModifiers(isImportingModel: $isImportingModel,
                                              isImportingProfile: $isImportingProfile))
            .dropDestination(for: URL.self) { urls, _ in
                model.acceptDroppedFiles(urls)
            }
            .sensoryFeedback(.success, trigger: model.successTick)
            .sensoryFeedback(.error, trigger: model.errorTick)
        }
    }
}

/// Import de documents + types acceptés, partagé par les deux dispositions.
struct DocumentImportModifiers: ViewModifier {
    @EnvironmentObject private var model: SlicerModel
    @Binding var isImportingModel: Bool
    @Binding var isImportingProfile: Bool

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isImportingModel,
                          allowedContentTypes: modelContentTypes,
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

    private var modelContentTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["stl", "3mf", "obj", "amf"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        types.append(.item)
        return types
    }
}

/// Aiguillage : deux colonnes sur iPad (classe de taille régulière), une sur iPhone.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            PadHomeView()
        } else {
            HomeView()
        }
    }
}
