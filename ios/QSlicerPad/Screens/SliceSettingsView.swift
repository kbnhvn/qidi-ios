//
//  SliceSettingsView.swift
//  Réglages fréquents : supports, adhérence, remplissage, qualité, température.
//  Ils s'appliquent *par-dessus* le preset QIDI sélectionné ; chaque réglage montre
//  la valeur héritée du preset, signale quand il est modifié et se remet à la
//  valeur du preset d'un geste.
//

import SwiftUI

struct SliceSettingsView: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss

    private var base: [String: String] { model.baseConfig }

    var body: some View {
        NavigationStack {
            Form {
                if base.isEmpty {
                    Section {
                        Label(L10n.t("Aucun preset résolu : les valeurs du profil ne sont pas affichées."),
                              systemImage: "info.circle")
                            .font(.footnote)
                    }
                }
                supportsSection
                adhesionSection
                infillSection
                qualitySection
                temperatureSection

                Section {
                    Button(role: .destructive) { model.overrides.resetAll() } label: {
                        Label(L10n.t("Tout remettre aux valeurs du profil"), systemImage: "arrow.uturn.backward")
                            .frame(minHeight: 44)
                    }
                    .disabled(model.overrides.isEmpty)
                } footer: {
                    Text(L10n.t("Seuls les réglages que vous modifiez sont appliqués ; tout le reste vient du profil QIDI choisi."))
                }
            }
            .navigationTitle(L10n.t("Réglages de slicing"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Terminé")) { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var supportsSection: some View {
        let keys = ["support_material", "support_material_auto", "support_material_buildplate_only"]
        return Section {
            Picker(L10n.t("Supports"), selection: Binding(
                get: { model.overrides.supportMode(base: base) },
                set: { model.overrides.setSupportMode($0, base: base) })) {
                Text(L10n.t("Aucun")).tag(SliceOverrides.SupportMode.none)
                Text(L10n.t("Sur le plateau uniquement")).tag(SliceOverrides.SupportMode.buildPlateOnly)
                Text(L10n.t("Renforts uniquement")).tag(SliceOverrides.SupportMode.enforcersOnly)
                Text(L10n.t("Partout")).tag(SliceOverrides.SupportMode.everywhere)
            }
            resetRow(keys)
        } header: { Text(L10n.t("Supports")) }
    }

    private var adhesionSection: some View {
        Section {
            Picker(L10n.t("Type"), selection: Binding(
                get: { model.overrides.adhesion(base: base) },
                set: { model.overrides.setAdhesion($0, base: base) })) {
                Text(L10n.t("Aucune")).tag(SliceOverrides.Adhesion.none)
                Text(L10n.t("Bordure (brim)")).tag(SliceOverrides.Adhesion.brim)
                Text(L10n.t("Radeau (raft)")).tag(SliceOverrides.Adhesion.raft)
            }
            switch model.overrides.adhesion(base: base) {
            case .brim:
                let width = Double(model.overrides.value("brim_width", base: base) ?? "5") ?? 5
                Stepper(value: Binding(
                    get: { width },
                    set: { model.overrides.set("brim_width", String(Int($0)), base: base) }),
                        in: 1...20, step: 1) {
                    LabeledContent(L10n.t("Largeur du brim"), value: "\(Int(width)) mm")
                }
            case .raft:
                let layers = Int(model.overrides.value("raft_layers", base: base) ?? "3") ?? 3
                Stepper(value: Binding(
                    get: { layers },
                    set: { model.overrides.set("raft_layers", String($0), base: base) }),
                        in: 1...8) {
                    LabeledContent(L10n.t("Couches de raft"), value: "\(layers)")
                }
            case .none:
                EmptyView()
            }
            resetRow(["brim_width", "raft_layers"])
        } header: { Text(L10n.t("Adhérence")) }
    }

    private var infillSection: some View {
        Section {
            let percent = model.overrides.infillPercent(base: base)
            Stepper(value: Binding(
                get: { percent },
                set: { model.overrides.setInfillPercent($0, base: base) }), in: 0...100, step: 5) {
                LabeledContent(L10n.t("Densité"), value: "\(percent) %")
            }
            resetRow(["fill_density"])
        } header: { Text(L10n.t("Remplissage")) }
    }

    private var qualitySection: some View {
        Section {
            let choices = SliceOverrides.layerHeightChoices(base: base)
            let current = model.overrides.layerHeight(base: base)
            Picker(L10n.t("Hauteur de couche"), selection: Binding(
                get: { choices.min(by: { abs($0 - current) < abs($1 - current) }) ?? current },
                set: { model.overrides.setLayerHeight($0, base: base) })) {
                ForEach(choices, id: \.self) { value in
                    Text(String(format: "%.2f mm", value)).tag(value)
                }
            }
            resetRow(["layer_height"])

            Stepper(value: Binding(
                get: { model.overrides.perimeters(base: base) },
                set: { model.overrides.setPerimeters($0, base: base) }), in: 1...10) {
                LabeledContent(L10n.t("Périmètres"), value: "\(model.overrides.perimeters(base: base))")
            }
            resetRow(["perimeters"])
        } header: { Text(L10n.t("Qualité")) }
    }

    private var temperatureSection: some View {
        Section {
            Stepper(value: $model.overrides.nozzleDelta, in: -30...30, step: 5) {
                LabeledContent(L10n.t("Buse"), value: String(format: "%+d °C", model.overrides.nozzleDelta))
            }
        } header: {
            Text(L10n.t("Température"))
        } footer: {
            Text(L10n.t("Le décalage s'ajoute à la température du filament du profil (utile pour un filament qui coule ou qui sous-extrude)."))
        }
    }

    // MARK: Aides

    /// Ligne « modifié » + bouton de retour à la valeur du profil, affichée seulement
    /// si l'un des réglages de la section est forcé.
    @ViewBuilder
    private func resetRow(_ keys: [String]) -> some View {
        if keys.contains(where: { model.overrides.isModified($0) }) {
            Button {
                for key in keys { model.overrides.reset(key) }
            } label: {
                Label(L10n.t("Modifié — revenir à la valeur du profil"), systemImage: "circle.fill")
                    .labelStyle(ModifiedLabelStyle())
                    .frame(minHeight: 44, alignment: .leading)
            }
        }
    }
}

private struct ModifiedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(.orange)
            configuration.title.font(.footnote)
        }
    }
}

#Preview {
    SliceSettingsView().environmentObject(SlicerModel())
}
