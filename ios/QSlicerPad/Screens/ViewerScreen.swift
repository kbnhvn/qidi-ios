//
//  ViewerScreen.swift
//  Visualiseur SceneKit : modèle 3D, ou trajectoires d'un G-code couche par couche.
//
//  Tactile : orbite/zoom au doigt (SceneKit), boutons de cadrage ≥ 44 pt, pas-à-pas
//  de couche, double-tap pour recadrer, et les mêmes commandes au clavier.
//

import SwiftUI
import SceneKit

enum ViewerContent {
    case model(STLMesh)
    case gcode(GCodePreview)
}

struct ViewerScreen: View {
    let content: ViewerContent

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
                .onTapGesture(count: 2) { frameCamera() }   // double-tap : recadrer
                .overlay(alignment: .topTrailing) { cameraBar }

            if case .gcode(let preview) = content, !preview.layers.isEmpty {
                layerBar(preview)
            }
        }
        .onAppear(perform: build)
    }

    // MARK: Barres tactiles

    private var cameraBar: some View {
        HStack(spacing: 6) {
            cameraButton(L10n.t("Recadrer"), "arrow.up.left.and.arrow.down.right") { frameCamera() }
            cameraButton(L10n.t("Dessus"), "square.grid.2x2") { setView(azimuth: 0, elevation: 90) }
            cameraButton(L10n.t("Face"), "rectangle") { setView(azimuth: 0, elevation: 0) }
            cameraButton(L10n.t("Isométrique"), "cube") { setView(azimuth: 45, elevation: 30) }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    private func cameraButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)      // cible tactile minimale Apple
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
    }

    private func layerBar(_ preview: GCodePreview) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    step(-1, max: preview.layers.count)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(layerIndex <= 0)

                VStack(spacing: 2) {
                    Text("\(L10n.t("Couche")) \(Int(layerIndex) + 1) / \(preview.layers.count)")
                        .font(.footnote.monospacedDigit())
                    Text(String(format: "Z %.2f mm", preview.layers[min(Int(layerIndex), preview.layers.count - 1)].z))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button {
                    step(1, max: preview.layers.count)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(layerIndex >= Double(max(preview.layers.count - 1, 0)))
            }

            Slider(value: $layerIndex, in: 0...Double(max(preview.layers.count - 1, 0)), step: 1) {
                Text(L10n.t("Couche"))
            } onEditingChanged: { _ in rebuild() }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func step(_ delta: Double, max count: Int) {
        layerIndex = min(max(layerIndex + delta, 0), Double(max(count - 1, 0)))
        rebuild()
    }

    // MARK: Scène

    private func build() {
        scene = SCNScene()
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 1
        cameraNode.camera?.zFar = 6000
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
        let distance = max(size * 2.2, 40)
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
        let distance = max(size * 2.4, 45)

        let az = azimuth * .pi / 180
        let el = elevation * .pi / 180
        cameraNode.position = SCNVector3(center.x + distance * cos(el) * sin(az),
                                         center.y - distance * cos(el) * cos(az),
                                         center.z + distance * sin(el))
        cameraNode.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
    }
}
