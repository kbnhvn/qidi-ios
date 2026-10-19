//
//  InspectorView.swift
//  Barre latérale (iPad) / feuille (iPhone) : presets, paramètres fréquents (comme
//  la barre latérale du bureau), objets de la scène et leur transformation,
//  slicing, résultat, envoi à l'imprimante.
//

import SwiftUI

/// « 0.20mm Standard @Q2 0.4 nozzle » → « 0.20mm Standard ».
func presetDisplayName(_ name: String) -> String { name.components(separatedBy: " @").first ?? name }

struct InspectorView: View {
    @EnvironmentObject private var model: SlicerModel
    @Binding var isImportingModel: Bool
    @Binding var isImportingProfile: Bool

    @State private var showQuickSettings = false
    @State private var showAllSettings = false
    @State private var showFilaments = false

    var body: some View {
        List {
            PresetsSection(isImportingProfile: $isImportingProfile, showFilaments: $showFilaments)
            FrequentSettingsSection(showQuick: $showQuickSettings, showAll: $showAllSettings)
            ObjectsSection(isImportingModel: $isImportingModel)
            if model.selectedObject != nil { TransformSection() }

            Section {
                SliceButton()
                if let status = model.statusLine, !model.isSlicing {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let output = model.output, let summary = model.summary {
                ResultSection(output: output, summary: summary)
                PrinterSection()
            }
            AboutSection()
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showQuickSettings) { SliceSettingsView().environmentObject(model) }
        .sheet(isPresented: $showAllSettings) { AllSettingsView().environmentObject(model) }
        .sheet(isPresented: $showFilaments) { FilamentPickerView().environmentObject(model) }
    }
}

// MARK: - Presets

struct PresetsSection: View {
    @EnvironmentObject private var model: SlicerModel
    @Binding var isImportingProfile: Bool
    @Binding var showFilaments: Bool

    var body: some View {
        Section {
            if !model.presetsReady {
                HStack { ProgressView(); Text(L10n.t("Chargement des profils…")).foregroundStyle(.secondary) }
            } else {
                Picker(L10n.t("Imprimante"), selection: Binding(
                    get: { model.selection.printer }, set: { model.selectPrinter($0) })) {
                    ForEach(model.printers, id: \.self) { Text($0).tag($0) }
                }
                Picker(L10n.t("Réglages d'impression"), selection: Binding(
                    get: { model.selection.print }, set: { model.selectPrint($0) })) {
                    ForEach(model.printPresets, id: \.self) { Text(presetDisplayName($0)).tag($0) }
                }
                Button { showFilaments = true } label: {
                    HStack {
                        Text(L10n.t("Filament")).foregroundStyle(.primary)
                        Spacer()
                        Text(model.selection.filament.isEmpty ? L10n.t("—") : presetDisplayName(model.selection.filament))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                }
            }

            Button { isImportingProfile = true } label: {
                Label(L10n.t("Importer un profil QIDISlicer (.ini)…"), systemImage: "doc.badge.plus").frame(minHeight: 44)
            }
            if model.importedProfile != nil {
                Button(role: .destructive) { model.clearProfile() } label: {
                    Label(L10n.t("Revenir aux profils embarqués"), systemImage: "arrow.uturn.backward").frame(minHeight: 44)
                }
            }
        } header: {
            Text(L10n.t("Profil d'impression"))
        } footer: {
            if model.importedProfile != nil {
                Text("\(L10n.t("Profil importé :")) \(model.activeProfileLabel)")
            }
        }
    }
}

// MARK: - Paramètres fréquents

/// Supports, remplissage, bordure : les trois réglages de la barre latérale du bureau.
struct FrequentSettingsSection: View {
    @EnvironmentObject private var model: SlicerModel
    @Binding var showQuick: Bool
    @Binding var showAll: Bool

    private var base: [String: String] { model.baseConfig }

    var body: some View {
        Section {
            Picker(L10n.t("Supports"), selection: Binding(
                get: { model.overrides.supportMode(base: base) },
                set: { model.overrides.setSupportMode($0, base: base) })) {
                Text(L10n.t("Aucun")).tag(SliceOverrides.SupportMode.none)
                Text(L10n.t("Sur le plateau uniquement")).tag(SliceOverrides.SupportMode.buildPlateOnly)
                Text(L10n.t("Renforts uniquement")).tag(SliceOverrides.SupportMode.enforcersOnly)
                Text(L10n.t("Partout")).tag(SliceOverrides.SupportMode.everywhere)
            }

            let percent = model.overrides.infillPercent(base: base)
            Stepper(value: Binding(
                get: { percent }, set: { model.overrides.setInfillPercent($0, base: base) }),
                    in: 0...100, step: 5) {
                LabeledContent(L10n.t("Remplissage"), value: "\(percent) %")
            }

            Toggle(L10n.t("Bordure (brim)"), isOn: Binding(
                get: { model.overrides.adhesion(base: base) == .brim },
                set: { model.overrides.setAdhesion($0 ? .brim : .none, base: base) }))

            if let summary = model.overrides.summary(base: base) {
                Text(summary).font(.footnote).foregroundStyle(.orange)
            }

            Button { showQuick = true } label: {
                Label(L10n.t("Plus de réglages rapides…"), systemImage: "slider.horizontal.3").frame(minHeight: 44)
            }
            Button { showAll = true } label: {
                Label(L10n.t("Tous les réglages…"), systemImage: "list.bullet.rectangle").frame(minHeight: 44)
            }
        } header: {
            Text(L10n.t("Paramètres fréquents"))
        }
    }
}

// MARK: - Objets

struct ObjectsSection: View {
    @EnvironmentObject private var model: SlicerModel
    @Binding var isImportingModel: Bool

    var body: some View {
        Section {
            ForEach(model.scene?.objects ?? []) { object in
                Button { model.selectedObjectID = object.id } label: {
                    HStack {
                        Image(systemName: object.instances.contains { $0.outside } ? "exclamationmark.triangle.fill" : "cube")
                            .foregroundStyle(object.instances.contains { $0.outside } ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(object.name).foregroundStyle(.primary).lineLimit(1)
                            Text(sizeText(object)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.selectedObjectID == object.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        model.selectedObjectID = object.id
                        model.deleteSelected()
                    } label: { Label(L10n.t("Supprimer"), systemImage: "trash") }
                }
            }
            Button { isImportingModel = true } label: {
                Label(L10n.t("Importer un modèle…"), systemImage: "square.and.arrow.down").frame(minHeight: 44)
            }
            if (model.scene?.objects.count ?? 0) > 1 {
                Button { model.arrange() } label: {
                    Label(L10n.t("Organiser"), systemImage: "square.grid.3x3.square").frame(minHeight: 44)
                }
            }
            if !(model.scene?.objects.isEmpty ?? true) {
                Button(role: .destructive) { model.clearScene() } label: {
                    Label(L10n.t("Vider le plateau"), systemImage: "trash").frame(minHeight: 44)
                }
            }
        } header: {
            Text(L10n.t("Objets"))
        }
    }

    private func sizeText(_ object: SceneObject) -> String {
        guard let instance = object.instances.first else { return "" }
        let s = instance.size
        let count = object.instances.count > 1 ? " · ×\(object.instances.count)" : ""
        return String(format: "%.1f × %.1f × %.1f mm", s[0], s[1], s[2]) + count
    }
}

// MARK: - Résultat

struct ResultSection: View {
    @EnvironmentObject private var model: SlicerModel
    let output: SlicerModel.SliceOutput
    let summary: SliceSummary

    var body: some View {
        Section {
            if model.resultIsStale {
                Label(L10n.t("Le plateau ou les réglages ont changé : re-slicez pour mettre à jour."),
                      systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent(L10n.t("Durée estimée"), value: summary.timeNormal.isEmpty ? formatDuration(seconds: summary.timeNormalS) : summary.timeNormal)
            if summary.timeSilentS > 0 {
                LabeledContent(L10n.t("Mode silencieux"), value: summary.timeSilent.isEmpty ? formatDuration(seconds: summary.timeSilentS) : summary.timeSilent)
            }
            LabeledContent(L10n.t("Filament"), value: String(format: "%.1f g · %.2f m", summary.filamentG, summary.filamentMm / 1000))
            if summary.cost > 0 { LabeledContent(L10n.t("Coût"), value: String(format: "%.2f", summary.cost)) }
            LabeledContent(L10n.t("Couches"), value: "\(summary.layers)")
            LabeledContent("G-code", value: output.url.lastPathComponent)
            LabeledContent(L10n.t("Taille"), value: ByteCountFormatter.string(fromByteCount: output.sizeBytes, countStyle: .file))
            ShareLink(item: output.url) {
                Label(L10n.t("Partager / exporter le G-code"), systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }
        } header: {
            Text(L10n.t("Résultat"))
        }
    }
}

struct PrinterSection: View {
    @EnvironmentObject private var model: SlicerModel

    var body: some View {
        Section(L10n.t("Imprimante")) {
            LabeledContent(L10n.t("Adresse"), value: model.moonraker.isConfigured
                           ? "\(model.moonraker.host):\(model.moonraker.port)"
                           : L10n.t("non configurée"))

            if let status = model.printerStatus {
                LabeledContent(L10n.t("État"), value: L10n.t(status.stateLabel))
                if !status.filename.isEmpty { LabeledContent(L10n.t("Fichier"), value: status.filename) }
                if status.state == "printing" || status.state == "paused" {
                    ProgressView(value: status.progress) { Text("\(Int(status.progress * 100)) %").font(.footnote.monospacedDigit()) }
                }
                if let nozzle = status.nozzle {
                    LabeledContent(L10n.t("Buse"), value: String(format: "%.0f / %.0f °C", nozzle, status.nozzleTarget ?? 0))
                }
                if let bed = status.bed {
                    LabeledContent(L10n.t("Plateau chauffant"), value: String(format: "%.0f / %.0f °C", bed, status.bedTarget ?? 0))
                }
            }

            Button { model.uploadAndPrint() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane")
                    Text(L10n.t("Envoyer et lancer l'impression")).font(.headline)
                    Spacer()
                    if model.isUploading { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .disabled(model.isUploading || !model.moonraker.isConfigured || model.resultIsStale)

            if let fraction = model.uploadProgress {
                ProgressView(value: fraction) { Text("\(L10n.t("Envoi")) \(Int(fraction * 100)) %").font(.footnote) }
            }
            if let status = model.uploadStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            Button(L10n.t("Actualiser l'état")) { model.refreshPrinterStatus() }
                .frame(minHeight: 44)
                .disabled(!model.moonraker.isConfigured)
        }
        // L'état est rafraîchi tant que la section est à l'écran.
        .task(id: model.moonraker) {
            guard model.moonraker.isConfigured else { return }
            while !Task.isCancelled {
                model.refreshPrinterStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

struct AboutSection: View {
    var body: some View {
        Section {
            Text(L10n.t("QSlicerPad est un portage iPadOS non officiel du moteur de QIDISlicer, distribué sous AGPL-3.0 — comme QIDISlicer, dont il dérive. Le code source de cette application est disponible avec l'archive du projet."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("QIDISlicer (QIDI Technology)", destination: URL(string: "https://github.com/QIDITECH/QIDISlicer")!)
                .font(.footnote)
                .frame(minHeight: 44)
        } header: {
            Text(L10n.t("À propos"))
        }
    }
}
