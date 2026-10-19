//
//  CalibrationSheet.swift
//  Paramètres d'une calibration (valeurs par défaut du bureau).
//

import SwiftUI

struct CalibrationSheet: View {
    enum Kind: String, Identifiable {
        case pressureAdvance, paLine, paPattern, flowFine, volumetricSpeed
        var id: String { rawValue }
        var isPressureAdvance: Bool { self == .pressureAdvance || self == .paLine || self == .paPattern }
    }

    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss
    let kind: Kind

    @State private var start = 0.0
    @State private var end = 0.04
    @State private var step = 0.002
    @State private var multiplier = 1.0
    @State private var vsStart = 5.0
    @State private var vsEnd = 20.0
    @State private var vsStep = 0.5

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .pressureAdvance, .paLine, .paPattern:
                    Section {
                        field(L10n.t("Début"), $start)
                        field(L10n.t("Fin"), $end)
                        field(L10n.t("Pas"), $step)
                    } footer: {
                        switch kind {
                        case .paLine:
                            Text(L10n.t("Une ligne par valeur de Pressure Advance (M900 K…) : lente, rapide, lente. Choisissez la ligne dont l'épaisseur est la plus régulière ; les valeurs sont listées dans l'ordre pendant la calibration."))
                        case .paPattern:
                            Text(L10n.t("Un chevron par valeur de Pressure Advance. Choisissez celui dont les angles sont les plus nets ; les valeurs sont listées dans l'ordre pendant la calibration."))
                        default:
                            Text(L10n.t("Le tour imprime une marche de 5 mm par valeur de Pressure Advance (M900 K…). Choisissez la hauteur où les angles sont les plus nets : K = début + pas × (hauteur / 5)."))
                        }
                    }
                case .volumetricSpeed:
                    Section {
                        field(L10n.t("Début (mm³/s)"), $vsStart)
                        field(L10n.t("Fin (mm³/s)"), $vsEnd)
                        field(L10n.t("Pas (mm³/s)"), $vsStep)
                    } footer: {
                        Text(L10n.t("Un mur d'un seul périmètre dont le débit augmente à chaque couche. Repérez la hauteur où l'extrusion devient irrégulière : le débit maximal du filament est juste en dessous."))
                    }
                case .flowFine:
                    Section {
                        field(L10n.t("Multiplicateur d'extrusion"), $multiplier)
                    } footer: {
                        Text(L10n.t("Saisissez la meilleure valeur de la calibration grossière pour l'affiner."))
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
                        case .paLine: model.startCalibration(.pressureAdvanceLine(start: start, end: end, step: step))
                        case .paPattern: model.startCalibration(.pressureAdvancePattern(start: start, end: end, step: step))
                        case .flowFine: model.startCalibration(.flowFine(multiplier: multiplier))
                        case .volumetricSpeed: model.startCalibration(.maxVolumetricSpeed(start: vsStart, end: vsEnd, step: vsStep))
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
