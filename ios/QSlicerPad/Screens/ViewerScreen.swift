//
//  ViewerScreen.swift
//  Visualiseur SceneKit : modèle 3D, ou trajectoires d'un G-code couche par couche.
//
//  SceneKit rend via Metal : pas de portage OpenGL ES nécessaire pour cette
//  première version (la voie « viewport C++ GLES partagé » reste ouverte pour
//  réutiliser GLCanvas3D/GCodeViewer de l'amont).
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

    var body: some View {
        VStack(spacing: 0) {
            SceneView(scene: scene,
                      pointOfView: cameraNode,
                      options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .ignoresSafeArea(edges: .horizontal)

            if case .gcode(let preview) = content, !preview.layers.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Text("\(L10n.t("Couche")) \(Int(layerIndex) + 1) / \(preview.layers.count)")
                            .font(.footnote.monospacedDigit())
                        Spacer()
                        Text(String(format: "Z %.2f mm", preview.layers[min(Int(layerIndex), preview.layers.count - 1)].z))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $layerIndex, in: 0...Double(max(preview.layers.count - 1, 0)), step: 1) {
                        Text(L10n.t("Couche"))
                    } onEditingChanged: { _ in rebuild() }
                }
                .padding()
                .background(.bar)
            }
        }
        .onAppear(perform: build)
    }

    // MARK: Construction de la scène

    private func build() {
        scene = SCNScene()
        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 1
        cameraNode.camera?.zFar = 5000
        scene.rootNode.addChildNode(cameraNode)

        let root = SCNNode()

        switch content {
        case .model(let mesh):
            let node = SCNNode(geometry: STLLoader.geometry(from: mesh))
            root.addChildNode(node)
        case .gcode:
            layerIndex = Double(max(0, (content.gcodeLayerCount ?? 1) - 1))
            break
        }

        scene.rootNode.addChildNode(root)
        if case .gcode = content { rebuild() }
        frameCamera(around: root)
    }

    private func rebuild() {
        // Retire l'ancien rendu de G-code, s'il existe.
        scene.rootNode.childNodes.filter { $0.name == "toolpaths" }.forEach { $0.removeFromParentNode() }
        guard case .gcode(let preview) = content else { return }
        guard let geometry = preview.geometry(upTo: Int(layerIndex)) else { return }
        let node = SCNNode(geometry: geometry)
        node.name = "toolpaths"
        scene.rootNode.addChildNode(node)
    }

    private func frameCamera(around node: SCNNode) {
        let (minBound, maxBound) = node.boundingBox
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
}

private extension ViewerContent {
    var gcodeLayerCount: Int? {
        if case .gcode(let preview) = self { return preview.layers.count }
        return nil
    }
}
