//
//  TransformSection.swift
//  Manipulation d'objet : position, rotation, échelle, taille en mm, instances —
//  le panneau « Object manipulation » du bureau. Les saisies sont validées par le
//  moteur (qui pose ensuite l'objet sur le plateau si besoin).
//

import SwiftUI

struct TransformSection: View {
    @EnvironmentObject private var model: SlicerModel
    @State private var uniformScale = true

    var body: some View {
        if let object = model.selectedObject, let instance = object.instances.first {
            Section {
                axisRow(title: L10n.t("Position (mm)"), values: instance.offset, decimals: 2) { axis, value in
                    var v = instance.offset; v[axis] = value
                    model.transform(objectID: object.id, offset: v)
                }
                axisRow(title: L10n.t("Rotation (°)"), values: instance.rotationDeg, decimals: 1) { axis, value in
                    var v = instance.rotationDeg; v[axis] = value
                    model.transform(objectID: object.id, rotationDeg: v, dropToBed: true)
                }
                axisRow(title: L10n.t("Échelle (%)"), values: instance.scale.map { $0 * 100 }, decimals: 1) { axis, value in
                    guard value > 0.01 else { return }
                    var v = instance.scale
                    if uniformScale {
                        let ratio = (value / 100) / max(v[axis], 1e-9)
                        v = v.map { $0 * ratio }
                    } else {
                        v[axis] = value / 100
                    }
                    model.transform(objectID: object.id, scale: v, dropToBed: true)
                }
                axisRow(title: L10n.t("Taille (mm)"), values: instance.size, decimals: 2) { axis, value in
                    guard value > 0.01, instance.size[axis] > 1e-9 else { return }
                    let ratio = value / instance.size[axis]
                    var v = instance.scale
                    if uniformScale { v = v.map { $0 * ratio } } else { v[axis] *= ratio }
                    model.transform(objectID: object.id, scale: v, dropToBed: true)
                }
                Toggle(L10n.t("Proportions verrouillées"), isOn: $uniformScale)

                Stepper(value: Binding(
                    get: { object.instances.count },
                    set: { model.setInstanceCount($0, objectID: object.id) }), in: 1...50) {
                    LabeledContent(L10n.t("Copies"), value: "\(object.instances.count)")
                }

                Menu {
                    Button(L10n.t("Pouces → mm (×25,4)")) { model.scaleSelected(by: 25.4) }
                    Button(L10n.t("Mètres → mm (×1000)")) { model.scaleSelected(by: 1000) }
                    Button(L10n.t("Millimètres → pouces (×1/25,4)")) { model.scaleSelected(by: 1 / 25.4) }
                } label: {
                    Label(L10n.t("Convertir les unités"), systemImage: "ruler").frame(minHeight: 44)
                }
            } header: {
                Text("\(L10n.t("Objet")) · \(object.name)")
            }

            Section {
                Button { model.beginCut() } label: {
                    Label(L10n.t("Couper…"), systemImage: "scissors").frame(minHeight: 44)
                }
                Button { model.activeTool = .simplify(object.id) } label: {
                    Label(L10n.t("Simplifier le maillage…"), systemImage: "square.3.layers.3d.down.right").frame(minHeight: 44)
                }
                Button { model.activeTool = .settings(object.id) } label: {
                    HStack {
                        Label(L10n.t("Réglages de l'objet…"), systemImage: "slider.horizontal.3")
                        Spacer()
                        if object.hasCustomSettings { Circle().fill(Color.orange).frame(width: 9, height: 9) }
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text(L10n.t("Outils"))
            }
        }
    }

    private func axisRow(title: String, values: [Double], decimals: Int,
                         commit: @escaping (Int, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { axis in
                    NumberField(label: ["X", "Y", "Z"][axis], value: values[axis], decimals: decimals) {
                        commit(axis, $0)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Champ numérique : édite un texte, valide à la touche Retour ou à la perte du focus.
struct NumberField: View {
    let label: String
    let value: Double
    var decimals = 2
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            TextField("", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 36)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, new in if !focused { text = format(new) } }
    }

    private func format(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(normalized) else { text = format(value); return }
        if abs(parsed - value) > pow(10, -Double(decimals)) / 2 { onCommit(parsed) }
        text = format(parsed)
    }
}
