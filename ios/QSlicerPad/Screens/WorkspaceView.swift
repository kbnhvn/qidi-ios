//
//  WorkspaceView.swift
//  Écran principal : le plateau est la scène centrale (Préparer / Aperçu), les
//  réglages sont dans un inspecteur à droite sur iPad, dans une feuille sur iPhone
//  et en Split View étroite — comme QIDISlicer desktop (plateau + barre latérale).
//

import SwiftUI
import UniformTypeIdentifiers

/// Point d'entrée de l'interface.
struct RootView: View {
    var body: some View { WorkspaceView() }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var isImportingModel = false
    @State private var isImportingProfile = false
    @State private var showSettings = false
    @State private var showInspector = false
    @State private var calibrationSheet: CalibrationSheet.Kind?

    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        NavigationStack {
            Group {
                if isRegular {
                    HStack(spacing: 0) {
                        canvas
                        Divider()
                        InspectorView(isImportingModel: $isImportingModel, isImportingProfile: $isImportingProfile)
                            .frame(width: 370)
                    }
                } else {
                    VStack(spacing: 0) {
                        canvas
                        compactBar
                    }
                }
            }
            .navigationTitle("QIDI Slice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
            .sheet(item: $calibrationSheet) { kind in CalibrationSheet(kind: kind).environmentObject(model) }
            .sheet(item: $model.activeTool) { tool in
                switch tool {
                case .simplify(let id): SimplifySheet(objectID: id).environmentObject(model)
                case .settings(let id): ObjectSettingsView(objectID: id).environmentObject(model)
                }
            }
            .sheet(isPresented: $showInspector) {
                NavigationStack {
                    InspectorView(isImportingModel: $isImportingModel, isImportingProfile: $isImportingProfile)
                        .navigationTitle(L10n.t("Réglages"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.t("Terminé")) { showInspector = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .modifier(DocumentImportModifiers(isImportingModel: $isImportingModel,
                                          isImportingProfile: $isImportingProfile))
        // Déposer un fichier depuis Fichiers, Shapr3D, AirDrop… agit comme un import.
        .dropDestination(for: URL.self) { urls, _ in model.acceptDroppedFiles(urls) }
        .sensoryFeedback(.success, trigger: model.successTick)
        .sensoryFeedback(.error, trigger: model.errorTick)
    }

    // MARK: Scène

    @ViewBuilder
    private var canvas: some View {
        switch model.workspace {
        case .prepare: PrepareCanvas(isImportingModel: $isImportingModel)
        case .preview: PreviewCanvas()
        }
    }

    // MARK: Barres

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(L10n.t("Mode"), selection: $model.workspace) {
                Text(L10n.t("Préparer")).tag(SlicerModel.Workspace.prepare)
                Text(L10n.t("Aperçu")).tag(SlicerModel.Workspace.preview)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: [.command])
                .accessibilityLabel(L10n.t("Annuler"))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityLabel(L10n.t("Rétablir"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { isImportingModel = true } label: { Image(systemName: "plus") }
                .keyboardShortcut("o", modifiers: [.command])
                .accessibilityLabel(L10n.t("Importer un modèle…"))
            Menu {
                Button(L10n.t("Pressure Advance (tour)…")) { calibrationSheet = .pressureAdvance }
                Button(L10n.t("Pressure Advance (ligne)…")) { calibrationSheet = .paLine }
                Button(L10n.t("Pressure Advance (motif)…")) { calibrationSheet = .paPattern }
                Button(L10n.t("Débit volumétrique maximal…")) { calibrationSheet = .volumetricSpeed }
                Button(L10n.t("Débit — calibration grossière")) { model.startCalibration(.flowCoarse) }
                Button(L10n.t("Débit — calibration fine…")) { calibrationSheet = .flowFine }
            } label: { Image(systemName: "gauge.with.dots.needle.33percent") }
                .accessibilityLabel(L10n.t("Calibration"))
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",", modifiers: [.command])
                .accessibilityLabel(L10n.t("Réglages"))
        }
    }

    /// iPhone / fenêtre étroite : bouton de slicing toujours visible + accès aux réglages.
    private var compactBar: some View {
        HStack(spacing: 12) {
            Button { showInspector = true } label: {
                Label(L10n.t("Réglages"), systemImage: "slider.horizontal.3")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            SliceButton(compact: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Bouton principal : « Slicer » (⌘↩) ; devient « Annuler » avec la progression pendant le calcul.
struct SliceButton: View {
    @EnvironmentObject private var model: SlicerModel
    var compact = false

    var body: some View {
        if model.isSlicing {
            VStack(spacing: 6) {
                ProgressView(value: model.progress)
                HStack {
                    Text(model.progressText.isEmpty ? L10n.t("Slicing…") : model.progressText)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("\(Int(model.progress * 100)) %").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    Button(role: .destructive) { model.cancel() } label: {
                        Label(L10n.t("Annuler"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        } else {
            Button { model.slice() } label: {
                Label(L10n.t(model.resultIsStale || model.output == nil ? "Slicer" : "Re-slicer"),
                      systemImage: "scissors")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSlice)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }
}

/// Import de documents + types acceptés.
struct DocumentImportModifiers: ViewModifier {
    @EnvironmentObject private var model: SlicerModel
    @Binding var isImportingModel: Bool
    @Binding var isImportingProfile: Bool

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isImportingModel,
                          allowedContentTypes: modelContentTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    for url in urls { model.importModel(from: url) }
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
