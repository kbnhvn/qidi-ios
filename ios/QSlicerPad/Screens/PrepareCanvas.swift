//
//  PrepareCanvas.swift
//  Mode « Préparer » : le plateau 3D et ses commandes flottantes (vues, actions sur
//  l'objet sélectionné, alertes d'import, état vide).
//

import SwiftUI

struct PrepareCanvas: View {
    @EnvironmentObject private var model: SlicerModel
    @Binding var isImportingModel: Bool

    var body: some View {
        ZStack {
            BedSceneView(model: model)
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 8) {
                banners
                if !model.calibrationLegend.isEmpty { CalibrationLegend() }
                Spacer()
                if model.cutPlane != nil {
                    CutPanel()
                } else if model.selectedObject != nil {
                    SelectionBar()
                }
            }
            .padding(10)

            HStack {
                ViewControls()
                Spacer()
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 56)

            if model.scene?.objects.isEmpty ?? true { emptyState }
        }
        .background(shortcuts)
    }

    private struct Nudge: Identifiable {
        let id: String
        let key: KeyEquivalent
        let dx: Double
        let dy: Double
    }

    private static let nudges = [
        Nudge(id: "left", key: .leftArrow, dx: -1, dy: 0), Nudge(id: "right", key: .rightArrow, dx: 1, dy: 0),
        Nudge(id: "up", key: .upArrow, dx: 0, dy: 1), Nudge(id: "down", key: .downArrow, dx: 0, dy: -1),
    ]

    /// Raccourcis clavier (clavier matériel iPad) : ⌥+flèches = 1 mm (⌥⇧ : 10 mm), ⌘D copie,
    /// ⌘A tout sélectionner, ⇧⌘A organise, Échap désélectionne. Les modificateurs évitent de gêner la saisie dans les champs numériques.
    private var shortcuts: some View {
        Group {
            ForEach(Self.nudges) { n in
                Button("") { model.nudgeSelected(dx: n.dx, dy: n.dy) }
                    .keyboardShortcut(n.key, modifiers: [.option])
                Button("") { model.nudgeSelected(dx: n.dx * 10, dy: n.dy * 10) }
                    .keyboardShortcut(n.key, modifiers: [.option, .shift])
            }
            Button("") { model.duplicateSelected() }.keyboardShortcut("d", modifiers: [.command])
            Button("") { model.arrange() }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("") { model.selectAll() }.keyboardShortcut("a", modifiers: [.command])
            Button("") { model.clearSelection() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Bandeaux

    @ViewBuilder
    private var banners: some View {
        if let alerts = model.sceneAlerts {
            if alerts.imperial {
                Banner(icon: "ruler", text: L10n.t("Ce modèle semble être en pouces."),
                       action: L10n.t("Convertir (×25,4)"),
                       perform: { model.scaleSelected(by: 25.4); model.dismissAlerts() },
                       dismiss: { model.dismissAlerts() })
            } else if alerts.savedInMeters {
                Banner(icon: "ruler", text: L10n.t("Ce modèle semble être en mètres."),
                       action: L10n.t("Convertir (×1000)"),
                       perform: { model.scaleSelected(by: 1000); model.dismissAlerts() },
                       dismiss: { model.dismissAlerts() })
            } else if alerts.multipart {
                Banner(icon: "square.on.square", text: L10n.t("Ce fichier semble composé de plusieurs pièces."),
                       action: nil, perform: {}, dismiss: { model.dismissAlerts() })
            } else if alerts.deletedObjects > 0 {
                Banner(icon: "trash", text: L10n.t("Des objets vides ont été ignorés."),
                       action: nil, perform: {}, dismiss: { model.dismissAlerts() })
            }
        }
        if model.scene?.hasObjectOutsideBed == true {
            Banner(icon: "exclamationmark.triangle.fill", text: L10n.t("Un objet sort du plateau."),
                   action: L10n.t("Organiser"), perform: { model.arrange() }, dismiss: nil)
        }
        if let error = model.errorMessage {
            Banner(icon: "exclamationmark.octagon.fill", text: error, action: nil, perform: {},
                   dismiss: { model.errorMessage = nil })
        }
        if let calibration = model.calibration {
            Banner(icon: "gauge.with.dots.needle.33percent",
                   text: "\(L10n.t("Calibration")) : \(L10n.t(calibration.title)) — \(L10n.t("réglages temporaires"))",
                   action: L10n.t("Quitter"), perform: { model.endCalibration() }, dismiss: nil)
        }
        if model.layOnFaceMode {
            Banner(icon: "square.3.layers.3d.down.forward",
                   text: L10n.t("Touchez la face qui doit reposer sur le plateau."),
                   action: L10n.t("Annuler"), perform: { model.layOnFaceMode = false }, dismiss: nil)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent").font(.system(size: 54)).foregroundStyle(.secondary)
            Text(L10n.t("Aucun modèle")).font(.title3.bold())
            Text(L10n.t("Importez un STL, 3MF, OBJ ou AMF — ou déposez le fichier dans l'app."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { isImportingModel = true } label: {
                Label(L10n.t("Importer un modèle…"), systemImage: "square.and.arrow.down")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(30)
    }
}

// MARK: - Commandes

/// Bandeau d'information avec une action facultative.
struct Banner: View {
    let icon: String
    let text: String
    let action: String?
    let perform: () -> Void
    let dismiss: (() -> Void)?

    init(icon: String, text: String, action: String?, perform: @escaping () -> Void, dismiss: (() -> Void)?) {
        self.icon = icon; self.text = text; self.action = action; self.perform = perform; self.dismiss = dismiss
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).font(.callout).lineLimit(3)
            Spacer(minLength: 4)
            if let action {
                Button(action, action: perform).buttonStyle(.bordered)
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(L10n.t("Fermer"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Aide à la lecture d'une calibration : valeur de chaque ligne, formule du débit…
struct CalibrationLegend: View {
    @EnvironmentObject private var model: SlicerModel
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.calibrationLegend.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } label: {
            Label(L10n.t("Lecture du résultat"), systemImage: "list.number").font(.callout.bold())
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 520)
    }
}

/// Vues prédéfinies de la caméra.
struct ViewControls: View {
    @EnvironmentObject private var model: SlicerModel

    var body: some View {
        VStack(spacing: 6) {
            button("arrow.up.left.and.arrow.down.right", L10n.t("Recadrer"), .frame)
            button("square.grid.2x2", L10n.t("Dessus"), .top)
            button("rectangle", L10n.t("Face"), .front)
            button("cube", L10n.t("Isométrique"), .iso)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func button(_ icon: String, _ label: String, _ kind: SlicerModel.CameraRequest.Kind) -> some View {
        Button { model.requestCamera(kind) } label: {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// Actions sur l'objet (ou le groupe d'objets) sélectionné.
struct SelectionBar: View {
    @EnvironmentObject private var model: SlicerModel

    var body: some View {
        if let object = model.selectedObject {
            let group = model.hasMultipleSelected
            VStack(spacing: 4) {
                if group {
                    Text(String(format: L10n.t("%ld objets sélectionnés"), model.selectedObjectIDs.count))
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        action("plus.square.on.square", L10n.t("Dupliquer")) { model.duplicateSelected() }
                        if !group {
                            action("square.3.layers.3d.down.forward", L10n.t("Poser sur une face"), active: model.layOnFaceMode) {
                                model.layOnFaceMode.toggle()
                            }
                        }
                        action("arrow.down.to.line", L10n.t("Poser sur le plateau")) { model.dropSelectedToBed() }
                        if !group {
                            action("dot.viewfinder", L10n.t("Centrer")) {
                                if let bed = model.scene?.bed, let inst = object.instances.first {
                                    model.transform(objectID: object.id,
                                                    offset: [(bed.minX + bed.maxX) / 2, (bed.minY + bed.maxY) / 2, inst.offset[2]])
                                }
                            }
                        }
                        action("arrow.counterclockwise", L10n.t("Orientation d'origine")) { model.resetRotationOfSelection() }
                        if !group {
                            action("scissors", L10n.t("Couper")) { model.beginCut() }
                            action("square.3.layers.3d.down.right", L10n.t("Simplifier")) { model.activeTool = .simplify(object.id) }
                            action("slider.horizontal.3", L10n.t("Réglages de l'objet"), badge: object.hasCustomSettings) {
                                model.activeTool = .settings(object.id)
                            }
                        }
                        action("checkmark.circle", L10n.t("Sélection multiple"), active: model.multiSelectMode) {
                            model.multiSelectMode.toggle()
                        }
                        action("square.dashed.inset.filled", L10n.t("Tout sélectionner")) { model.selectAll() }
                        action("square.grid.3x3.square", L10n.t("Organiser")) { model.arrange() }
                        action("trash", L10n.t("Supprimer"), role: .destructive) { model.deleteSelected() }
                            .keyboardShortcut(.delete, modifiers: [])
                    }
                    .padding(6)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: 640)
            }
        }
    }

    private func action(_ icon: String, _ label: String, active: Bool = false, badge: Bool = false,
                        role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if badge { Circle().fill(Color.orange).frame(width: 9, height: 9).offset(x: 6, y: -4) }
                    }
                Text(label).font(.caption2).lineLimit(1)
            }
            .frame(width: 78, height: 54)
            .background(active ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}
