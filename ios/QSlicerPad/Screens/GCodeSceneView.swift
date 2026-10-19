//
//  GCodeSceneView.swift
//  Aperçu 3D du G-code : un nœud SceneKit par couche (rubans à la largeur et à la
//  hauteur réelles, générés par Core/GCodeMesh.swift), la plage de couches visible
//  se règle en masquant des nœuds — aucune reconstruction de géométrie au curseur.
//

import SwiftUI
import SceneKit
import UIKit
import simd

struct GCodeSceneView: UIViewRepresentable {
    let mesh: GCodeMesh?
    /// Plage de couches affichées (indices inclus).
    let layerRange: ClosedRange<Int>
    let bed: SceneBed?
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.16, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(mesh: mesh, range: layerRange, bed: bed, revision: revision)
    }

    // MARK: Coordinateur

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let contentNode = SCNNode()
        private var layerNodes: [SCNNode] = []
        private var orbit = OrbitCamera(target: Vec3(135, 135, 20), distance: 500, azimuth: 25, elevation: 40)
        private weak var view: SCNView?
        private var lastRevision = -1
        private var lastBedSignature = ""
        private var lastRange: ClosedRange<Int>?

        override init() {
            super.init()
            let camera = SCNCamera()
            camera.fieldOfView = orbit.fovDegrees
            camera.zNear = 1
            camera.zFar = 8000
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)
            scene.rootNode.addChildNode(contentNode)
            apply()
        }

        func attach(to view: SCNView) {
            self.view = view
            view.scene = scene
            view.pointOfView = cameraNode
            let one = UIPanGestureRecognizer(target: self, action: #selector(orbitGesture(_:)))
            one.minimumNumberOfTouches = 1; one.maximumNumberOfTouches = 1
            let two = UIPanGestureRecognizer(target: self, action: #selector(panGesture(_:)))
            two.minimumNumberOfTouches = 2; two.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchGesture(_:)))
            let double = UITapGestureRecognizer(target: self, action: #selector(frameGesture(_:)))
            double.numberOfTapsRequired = 2
            [one, two, pinch, double].forEach { $0.delegate = self; view.addGestureRecognizer($0) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Contenu

        func update(mesh: GCodeMesh?, range: ClosedRange<Int>, bed: SceneBed?, revision: Int) {
            if let bed { syncBed(bed) }
            if revision != lastRevision {
                lastRevision = revision
                rebuild(mesh)
                lastRange = nil
            }
            if range != lastRange {
                lastRange = range
                for (index, node) in layerNodes.enumerated() { node.isHidden = !range.contains(index) }
            }
        }

        private func rebuild(_ mesh: GCodeMesh?) {
            layerNodes.forEach { $0.removeFromParentNode() }
            layerNodes = []
            guard let mesh else { return }
            let ribbonMaterial = SCNMaterial()
            ribbonMaterial.lightingModel = .constant   // l'ombrage est déjà dans les couleurs des sommets
            ribbonMaterial.isDoubleSided = true
            let travelMaterial = SCNMaterial()
            travelMaterial.diffuse.contents = UIColor(white: 0.7, alpha: 0.5)
            travelMaterial.lightingModel = .constant

            for layer in mesh.layers {
                let node = SCNNode()
                if !layer.indices.isEmpty {
                    let vertexCount = layer.positions.count / 3
                    let positions = layer.positions.withUnsafeBufferPointer { Data(buffer: $0) }
                    let source = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: vertexCount,
                                                   usesFloatComponents: true, componentsPerVector: 3,
                                                   bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
                    // SceneKit attend des couleurs flottantes
                    var rgba = [Float](); rgba.reserveCapacity(layer.colors.count)
                    for c in layer.colors { rgba.append(Float(c) / 255) }
                    let colors = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
                    let colorSource = SCNGeometrySource(data: colors, semantic: .color, vectorCount: vertexCount,
                                                        usesFloatComponents: true, componentsPerVector: 4,
                                                        bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
                    let element = SCNGeometryElement(indices: layer.indices, primitiveType: .triangles)
                    let geometry = SCNGeometry(sources: [source, colorSource], elements: [element])
                    geometry.materials = [ribbonMaterial]
                    node.addChildNode(SCNNode(geometry: geometry))
                }
                if !layer.travel.isEmpty {
                    var points: [SCNVector3] = []
                    points.reserveCapacity(layer.travel.count / 3)
                    for i in stride(from: 0, to: layer.travel.count - 2, by: 3) {
                        points.append(SCNVector3(layer.travel[i], layer.travel[i + 1], layer.travel[i + 2]))
                    }
                    let source = SCNGeometrySource(vertices: points)
                    let element = SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .line)
                    let geometry = SCNGeometry(sources: [source], elements: [element])
                    geometry.materials = [travelMaterial]
                    node.addChildNode(SCNNode(geometry: geometry))
                }
                contentNode.addChildNode(node)
                layerNodes.append(node)
            }
            if mesh.boundsMax != mesh.boundsMin {
                let lo = Vec3(Double(mesh.boundsMin.x), Double(mesh.boundsMin.y), 0)
                let hi = Vec3(Double(mesh.boundsMax.x), Double(mesh.boundsMax.y), Double(mesh.boundsMax.z))
                orbit.frame(min: lo, max: hi, aspect: Double((view?.bounds.width ?? 1) / max(view?.bounds.height ?? 1, 1)))
                apply()
            }
        }

        private let bedNode = SCNNode()

        private func syncBed(_ bed: SceneBed) {
            let signature = "\(bed.shape)"
            guard signature != lastBedSignature else { return }
            lastBedSignature = signature
            bedNode.removeFromParentNode()
            bedNode.childNodes.forEach { $0.removeFromParentNode() }
            var points: [SCNVector3] = []
            for i in 0..<bed.shape.count {
                let a = bed.shape[i], b = bed.shape[(i + 1) % bed.shape.count]
                points += [SCNVector3(Float(a[0]), Float(a[1]), 0), SCNVector3(Float(b[0]), Float(b[1]), 0)]
            }
            let source = SCNGeometrySource(vertices: points)
            let element = SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(white: 1, alpha: 0.35)
            material.lightingModel = .constant
            geometry.materials = [material]
            bedNode.addChildNode(SCNNode(geometry: geometry))
            scene.rootNode.addChildNode(bedNode)
        }

        // MARK: Caméra

        private func apply() {
            let p = orbit.position
            cameraNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
            cameraNode.look(at: SCNVector3(Float(orbit.target.x), Float(orbit.target.y), Float(orbit.target.z)),
                            up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        }

        @objc private func orbitGesture(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed else { return }
            let t = g.translation(in: view)
            orbit.orbit(deltaX: Double(t.x), deltaY: Double(t.y))
            g.setTranslation(.zero, in: view)
            apply()
        }

        @objc private func panGesture(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed else { return }
            let t = g.translation(in: view)
            orbit.pan(deltaX: Double(t.x), deltaY: Double(t.y), viewHeight: Double(view?.bounds.height ?? 1))
            g.setTranslation(.zero, in: view)
            apply()
        }

        @objc private func pinchGesture(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed else { return }
            orbit.zoom(scale: Double(g.scale))
            g.scale = 1
            apply()
        }

        @objc private func frameGesture(_ g: UITapGestureRecognizer) {
            guard !layerNodes.isEmpty else { return }
            let bounds = contentNode.boundingBox
            orbit.frame(min: Vec3(Double(bounds.min.x), Double(bounds.min.y), Double(bounds.min.z)),
                        max: Vec3(Double(bounds.max.x), Double(bounds.max.y), Double(bounds.max.z)),
                        aspect: Double((view?.bounds.width ?? 1) / max(view?.bounds.height ?? 1, 1)))
            apply()
        }
    }
}
