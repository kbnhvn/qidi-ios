//
//  MultiFilamentSection.swift
//  Impression multi-couleur : nombre de filaments (jusqu'à 16, QIDI Box), filament et couleur
//  de chacun, association aux emplacements du Box.
//

import SwiftUI
import UIKit

struct MultiFilamentSection: View {
    @EnvironmentObject private var model: SlicerModel

    var body: some View {
        Section {
            Stepper(value: Binding(get: { model.extruderCount }, set: { model.setExtruderCount($0) }),
                    in: 1...QIDIBox.slotCount) {
                LabeledContent(L10n.t("Filaments"), value: "\(model.extruderCount)")
            }

            if model.isMultiFilament {
                let colors = model.filamentColors
                ForEach(0..<model.extruderCount, id: \.self) { index in
                    HStack(spacing: 10) {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: index < colors.count ? colors[index] : "#999999") },
                            set: { model.setFilamentColor(index, hex: $0.hexString) }), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 44)
                            .accessibilityLabel("\(L10n.t("Couleur")) T\(index + 1)")
                        Text("T\(index + 1)").font(.callout.monospacedDigit().bold()).frame(width: 34, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { index < model.extruderFilaments.count ? model.extruderFilaments[index] : "" },
                            set: { model.setExtruderFilament(index, $0) })) {
                            ForEach(model.filamentPresets, id: \.self) { name in
                                Text(name.components(separatedBy: " @").first ?? name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.useBox {
                            Picker("", selection: Binding(
                                get: { index < model.boxSlots.count ? model.boxSlots[index] : index },
                                set: { newValue in
                                    var slots = model.boxSlots
                                    while slots.count <= index { slots.append(slots.count) }
                                    slots[index] = newValue
                                    model.boxSlots = slots
                                })) {
                                ForEach(QIDIBox.allTrays, id: \.slot) { Text($0.name).tag($0.slot) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .accessibilityLabel(L10n.t("Emplacement du Box"))
                        }
                    }
                    .frame(minHeight: 44)
                }
            }

            Toggle(isOn: $model.useBox) {
                Label(L10n.t("Utiliser le QIDI Box"), systemImage: "shippingbox").frame(minHeight: 44)
            }
            if model.useBox {
                Button { model.readBoxFromPrinter() } label: {
                    Label(L10n.t("Lire l'association dans l'imprimante"), systemImage: "arrow.down.circle").frame(minHeight: 44)
                }
                .disabled(!model.moonraker.isConfigured)
                if let status = model.boxStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.t("Multi-filament"))
        } footer: {
            Text(L10n.t("Plusieurs filaments : choisissez le filament de chaque objet dans « Réglages de l'objet ». Avec le QIDI Box, l'association des outils aux emplacements est envoyée à l'imprimante au lancement de l'impression."))
        }
    }
}

extension Color {
    /// « #RRGGBB » (gris si illisible).
    init(hex: String) {
        let rgb = GCodeMeshBuilder.parseColors(hex).first ?? (160, 160, 160)
        self.init(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
