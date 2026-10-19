//
//  ViewerScreen.swift
//  Visualiseur SceneKit : modèle 3D, ou trajectoires d'un G-code couche par couche.
//
//  Présenté en feuille (sheet) avec un bouton « Terminé » : on ne peut plus rester
//  coincé dans une navigation poussée. Les commandes sont sous la scène, en gros
//  boutons légendés (pas d'overlay dont les taps peuvent être perdus).
//

import SwiftUI
import SceneKit

enum ViewerContent {
    case model(STLMesh)
    case gcode(GCodePreview)

    var layerCount: Int? {
        if case .gcode(let preview) = self { return preview.layers.count }
        return nil
    }
}

struct ViewerScreen: View {
    let content: ViewerContent

    @Environment(\.dismiss) private var dismiss

    @State private var layerIndex: Double = 0
    @State private var scene = SCNScene()
    @State private var cameraNode = SCNNode()
    /// Nœud du modèle (le G-code, lui, vit dans le nœud « toolpaths »).
    @State private var contentNode = SCNNode()

    var body: some View {
        VStack(spacing: 0) {
            SceneView(scene: scene,
                      pointOfView: cameraNode,
                      options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .ignoresSafeArea(edges: .horizontal)
                .onTapGesture(count: 2) { frameCamera() }
                .overlay(alignment: .bottomTrailing) {
                    Text(L10n.t("Un doigt : orbite · deux doigts : déplacer · pincement : zoom · double-tap : recadrer"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }

            cameraBar
            if let count = content.layerCount, count > 0 { layerBar(count, preview: content) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("Terminé")) { dismiss() }
            }
        }
        .onAppear(perform: build)
    }

    private var title: String {
        if case .gcode = content { return L10n.t("Aperçu G-code") }
        return L10n.t("Modèle")
    }

    // MARK: Commandes tactiles

    private var cameraBar: some View {
        HStack(spacing: 8) {
            cameraButton(L10n.t("Recadrer"), "arrow.up.left.and.arrow.down.right") { frameCamera() }
            cameraButton(L10n.t("Dessus"), "square.grid.2x2") { setView(azimuth: 0, elevation: 90) }
            cameraButton(L10n.t("Face"), "rectangle") { setView(azimuth: 0, elevation: 0) }
            cameraButton(L10n.t("Isométrique"), "cube") { setView(azimuth: 45, elevation: 30) }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func cameraButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
    }

    private func layerBar(_ count: Int, preview: ViewerContent) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button { step(-1, count: count) } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 26))
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(layerIndex <= 0)

                VStack(spacing: 2) {
                    Text("\(L10n.t("Couche")) \(Int(layerIndex) + 1) / \(count)")
                        .font(.footnote.monospacedDigit())
                    if case .gcode(let p) = preview, !p.layers.isEmpty {
                        let index = min(Int(layerIndex), p.layers.count - 1)
                        Text(String(format: "Z %.2f mm", p.layers[index].z))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                Button { step(1, count: count) } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 26))
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(layerIndex >= Double(max(count - 1, 0)))
            }

            Slider(value: $layerIndex, in: 0...Double(max(count - 1, 0)), step: 1) {
                Text(L10n.t("Couche"))
            } onEditingChanged: { _ in rebuild() }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func step(_ delta: Double, count: Int) {
        layerIndex = min(max(layerIndex + delta, 0), Double(max(count - 1, 0)))
        rebuild()
    }

    // MARK: Scène

    private func build() {
        scene = SCNScene()
        cameraNode = SCNNode()
        // La caméra doit avoir une distance de vision large : les modèles sont en mm.
        let camera = SCNCamera()
        camera.zNear = 0.5
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        contentNode = SCNNode()
        switch content {
        case .model(let mesh):
            contentNode.addChildNode(SCNNode(geometry: STLLoader.geometry(from: mesh)))
        case .gcode(let preview):
            layerIndex = Double(max(preview.layers.count - 1, 0))
        }
        scene.rootNode.addChildNode(contentNode)
        if case .gcode = content { rebuild() }
        frameCamera()
    }

    private func rebuild() {
        scene.rootNode.childNodes.filter { $0.name == "toolpaths" }.forEach { $0.removeFromParentNode() }
        guard case .gcode(let preview) = content,
              let geometry = preview.geometry(upTo: Int(layerIndex)) else { return }
        let node = SCNNode(geometry: geometry)
        node.name = "toolpaths"
        scene.rootNode.addChildNode(node)
    }

    /// Objet à cadrer : le G-code quand il est affiché, sinon le modèle.
    private var framedNode: SCNNode {
        scene.rootNode.childNode(withName: "toolpaths", recursively: false) ?? contentNode
    }

    private func frameCamera() {
        let (minBound, maxBound) = framedNode.boundingBox
        let center = SCNVector3((minBound.x + maxBound.x) / 2,
                                (minBound.y + maxBound.y) / 2,
                                (minBound.z + maxBound.z) / 2)
        let size = max(maxBound.x - minBound.x, max(maxBound.y - minBound.y, maxBound.z - minBound.z))
        let distance = max(Float(size) * 2.2, 40)
        cameraNode.position = SCNVector3(center.x + distance * 0.6,
                                         center.y - distance * 0.6,
                                         center.z + distance * 0.9)
        cameraNode.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
    }

    /// Vues prédéfinies (azimut/élévation en degrés) autour de l'objet.
    private func setView(azimuth: Float, elevation: Float) {
        let (minBound, maxBound) = framedNode.boundingBox
        let center = SCNVector3((minBound.x + maxBound.x) / 2,
                                (minBound.y + maxBound.y) / 2,
                                (minBound.z + maxBound.z) / 2)
        let size = max(maxBound.x - minBound.x, max(maxBound.y - minBound.y, maxBound.z - minBound.z))
        let distance = max(Float(size) * 2.4, 45)

        let az = azimuth * .pi / 180
        let el = elevation * .pi / 180
        cameraNode.position = SCNVector3(center.x + distance * cos(el) * sin(az),
                                         center.y - distance * cos(el) * cos(az),
                                         center.z + distance * sin(el))
        cameraNode.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
    }
}
