//
//  CalibrationSheet.swift
//  Paramètres d'une calibration (valeurs par défaut du bureau).
//

import SwiftUI

struct CalibrationSheet: View {
    enum Kind: String, Identifiable { case pressureAdvance, flowFine; var id: String { rawValue } }

    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss
    let kind: Kind

    @State private var start = 0.0
    @State private var end = 0.04
    @State private var step = 0.002
    @State private var multiplier = 1.0

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .pressureAdvance:
                    Section {
                        field(L10n.t("Début"), $start)
                        field(L10n.t("Fin"), $end)
                        field(L10n.t("Pas"), $step)
                    } footer: {
                        Text(L10n.t("Le tour imprime une marche de 5 mm par valeur de Pressure Advance (M900 K…). Choisissez la hauteur où les angles sont les plus nets : K = début + pas × (hauteur / 5)."))
                    }
                case .flowFine:
                    Section {
                        field(L10n.t("Multiplicateur d'extrusion"), $multiplier)
                    } footer: {
                        Text(L10n.t("Saisissez la meilleure valeur de la calibration grossière pour la affiner."))
                    }
                }
                Section {
                    Text(L10n.t(CalibrationPlan.notice)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.t("Calibration"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Annuler")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Préparer")) {
                        switch kind {
                        case .pressureAdvance: model.startCalibration(.pressureAdvanceTower(start: start, end: end, step: step))
                        case .flowFine: model.startCalibration(.flowFine(multiplier: multiplier))
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .textFieldStyle(.roundedBorder)
        }
    }
}
