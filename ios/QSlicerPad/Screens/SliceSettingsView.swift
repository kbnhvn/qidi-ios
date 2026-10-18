//
//  SliceSettingsView.swift
//  Réglages de slicing accessibles depuis l'app : supports, adhérence,
//  remplissage, qualité, solides, température. Ils s'appliquent *par-dessus* le
//  preset QIDI sélectionné.
//

import SwiftUI

struct SliceSettingsView: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.t("Utiliser ces options"), isOn: $model.overrides.enabled)
                } footer: {
                    Text(L10n.t("Elles s'appliquent par-dessus le profil QIDI choisi (supports, adhérence, remplissage…). Désactivées, le profil est utilisé tel quel."))
                }

                Section(L10n.t("Supports")) {
                    Toggle(L10n.t("Générer des supports"), isOn: $model.overrides.supports)
                        .disabled(!model.overrides.enabled)
                    if model.overrides.supports {
                        Stepper(value: $model.overrides.supportThreshold, in: 10...70, step: 5) {
                            LabeledContent(L10n.t("Seuil d'inclinaison"), value: "\(Int(model.overrides.supportThreshold)) °")
                        }
                        .disabled(!model.overrides.enabled)
                    }
                }

                Section(L10n.t("Adhérence")) {
                    Picker(L10n.t("Type"), selection: $model.overrides.adhesion) {
                        Text(L10n.t("Aucune")).tag(SliceOverrides.Adhesion.none)
                        Text(L10n.t("Bordure (brim)")).tag(SliceOverrides.Adhesion.brim)
                        Text(L10n.t("Radeau (raft)")).tag(SliceOverrides.Adhesion.raft)
                    }
                    .disabled(!model.overrides.enabled)

                    if model.overrides.adhesion == .brim {
                        Stepper(value: $model.overrides.brimWidth, in: 2...20, step: 1) {
                            LabeledContent(L10n.t("Largeur du brim"), value: String(format: "%.0f mm", model.overrides.brimWidth))
                        }
                        .disabled(!model.overrides.enabled)
                    } else if model.overrides.adhesion == .raft {
                        Stepper(value: $model.overrides.raftLayers, in: 1...8) {
                            LabeledContent(L10n.t("Couches de raft"), value: "\(model.overrides.raftLayers)")
                        }
                        .disabled(!model.overrides.enabled)
                    }
                }

                Section(L10n.t("Remplissage")) {
                    Stepper(value: $model.overrides.infillDensity, in: 0...100, step: 5) {
                        LabeledContent(L10n.t("Densité"), value: "\(model.overrides.infillDensity) %")
                    }
                    .disabled(!model.overrides.enabled)
                }

                Section(L10n.t("Qualité")) {
                    Picker(L10n.t("Hauteur de couche"), selection: $model.overrides.layerHeight) {
                        Text(L10n.t("Celle du profil")).tag(0.0)
                        ForEach(SliceOverrides.layerHeights.filter { $0 > 0 }, id: \.self) { value in
                            Text(String(format: "%.2f mm", value)).tag(value)
                        }
                    }
                    .disabled(!model.overrides.enabled)

                    Stepper(value: $model.overrides.perimeters, in: 0...8) {
                        LabeledContent(L10n.t("Périmètres"),
                                       value: model.overrides.perimeters == 0
                                            ? L10n.t("Ceux du profil")
                                            : "\(model.overrides.perimeters)")
                    }
                    .disabled(!model.overrides.enabled)
                }

                Section(L10n.t("Température")) {
                    Stepper(value: $model.overrides.nozzleDelta, in: -20...20, step: 5) {
                        LabeledContent(L10n.t("Buse"),
                                       value: String(format: "%+d °C", model.overrides.nozzleDelta))
                    }
                    .disabled(!model.overrides.enabled)
                } footer: {
                    Text(L10n.t("Le décalage s'ajoute à la température du filament du profil (utile pour un filament qui coule ou qui sous-extrude)."))
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
}

#Preview {
    SliceSettingsView().environmentObject(SlicerModel())
}
