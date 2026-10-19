//
//  BedSceneView.swift
//  Plateau 3D : le plateau de l'imprimante, les objets posés dessus, sélection,
//  déplacement au doigt, rotation à deux doigts, caméra orbitale.
//
//  Les gestes sont gérés ici (pas de `allowsCameraControl`) pour pouvoir distinguer
//  « je déplace un objet » de « je tourne la caméra » : un doigt sur un objet le
//  déplace, un doigt dans le vide oriente la caméra, deux doigts font le
//  panoramique, le pincement zoome, la rotation à deux doigts tourne l'objet
//  sélectionné autour de Z. Toute la géométrie (rayons, intersections, caméra) est
//  dans Core/BedGeometry.swift, testée sous Linux ; cette vue n'est que la colle.
//

import SwiftUI
import SceneKit
import UIKit
import simd

struct BedSceneView: UIViewRepresentable {
    @ObservedObject var model: SlicerModel

    func makeCoordinator() -> BedSceneCoordinator { BedSceneCoordinator(model: model) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.16, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.sync()
    }
}

// MARK: - Coordinateur

@MainActor
final class BedSceneCoordinator: NSObject, UIGestureRecognizerDelegate {
    private let model: SlicerModel
    private weak var view: SCNView?

    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let bedNode = SCNNode()
    private let objectsNode = SCNNode()
    private var orbit = OrbitCamera(target: Vec3(135, 135, 0), distance: 600, azimuth: 20, elevation: 40)

    private var instanceNodes: [String: SCNNode] = [:]
    private var geometries: [UInt64: (count: Int, geometry: SCNGeometry)] = [:]
    private var bedSignature = ""
    private var lastScene: SceneInfo?
    private var lastSelection: Set<UInt64> = []
    private var lastCut: CutPlane?
    private let cutNode = SCNNode()
    private var lastMeshCounts: [UInt64: Int] = [:]
    private var handledCameraToken = 0
    /// Le premier cadrage se fait avant que la vue ait sa taille : on le refait une fois, taille connue.
    private var framedWithRealSize = false

    // état d'un geste
    /// Une instance déplacée par le geste (un seul objet, ou tout le groupe sélectionné).
    private struct Mover {
        var id: UInt64
        var instance: Int
        var startMatrix: simd_float4x4
        var startOffset: [Double]
        var boxMin: Vec3
        var boxMax: Vec3
    }

    private enum Drag {
        case objects(movers: [Mover], startHit: Vec3, planeZ: Double)
        case orbit
    }
    private var drag: Drag?
    private var lastPan = CGPoint.zero
    private var rotationStart: (id: UInt64, matrix: simd_float4x4, rotationZ: Double)?
    private var wasOutsideDuringDrag = false
    private var isDraggingObject: Bool {
        if case .some(.objects) = drag { return true }
        return false
    }

    init(model: SlicerModel) {
        self.model = model
        super.init()
        buildScene()
    }

    // MARK: Scène

    private func buildScene() {
        let camera = SCNCamera()
        camera.fieldOfView = orbit.fovDegrees
        camera.zNear = 1
        camera.zFar = 8000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(bedNode)
        scene.rootNode.addChildNode(objectsNode)
        scene.rootNode.addChildNode(cutNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 520
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        scene.rootNode.addChildNode(sun)
        applyCamera()
    }

    func attach(to view: SCNView) {
        self.view = view
        view.scene = scene
        view.pointOfView = cameraNode

        let one = UIPanGestureRecognizer(target: self, action: #selector(handleOneFinger(_:)))
        one.minimumNumberOfTouches = 1; one.maximumNumberOfTouches = 1; one.delegate = self
        let two = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFinger(_:)))
        two.minimumNumberOfTouches = 2; two.maximumNumberOfTouches = 2; two.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        [one, two, pinch, rotation, tap, doubleTap].forEach { view.addGestureRecognizer($0) }
        // Appui long (ou clic droit) sur un objet : menu contextuel.
        view.addInteraction(UIContextMenuInteraction(delegate: self))
        sync()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // pincement + rotation + panoramique à deux doigts ensemble ; le doigt seul reste exclusif
        let oneFinger = { (r: UIGestureRecognizer) in (r as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1 }
        return !(oneFinger(g) || oneFinger(other))
    }

    // MARK: Synchronisation avec le modèle

    func sync() {
        guard let view else { return }
        handleCameraRequest()
        if !framedWithRealSize, view.bounds.width > 10, model.scene != nil {
            framedWithRealSize = true
            frameBed()
        }

        let scene = model.scene
        let selection = model.selectedObjectIDs
        let counts = model.meshes.mapValues(\.count)
        let cut = model.cutPlane
        if scene == lastScene, selection == lastSelection, counts == lastMeshCounts, cut == lastCut { return }
        // pendant un geste d'objet, la vue fait foi : on ne l'écrase pas
        if isDraggingObject { return }
        lastScene = scene; lastSelection = selection; lastMeshCounts = counts; lastCut = cut

        if let scene { syncBed(scene.bed) }
        syncObjects(scene, selection: selection)
        syncCutPlane(scene, plane: cut)
    }

    private func handleCameraRequest() {
        guard let request = model.cameraRequest, request.token != handledCameraToken else { return }
        handledCameraToken = request.token
        let bed = model.scene?.bed
        let center = bed.map { Vec3(($0.minX + $0.maxX) / 2, ($0.minY + $0.maxY) / 2, 0) } ?? orbit.target
        let size = bed.map { max($0.width, $0.depth) } ?? 270
        switch request.kind {
        case .frame:
            frameBed()
        case .top:
            orbit = .preset(.top, target: center, distance: size * 1.9)
        case .front:
            orbit = .preset(.front, target: center + Vec3(0, 0, size * 0.1), distance: size * 1.9)
        case .iso:
            orbit = .preset(.isometric, target: center, distance: size * 1.7)
        }
        applyCamera()
    }

    private func frameBed() {
        guard let bed = model.scene?.bed else { return }
        let aspect = Double((view?.bounds.width ?? 1) / max(view?.bounds.height ?? 1, 1))
        orbit.azimuth = 20; orbit.elevation = 40
        orbit.frame(min: Vec3(bed.minX, bed.minY, 0), max: Vec3(bed.maxX, bed.maxY, min(bed.maxHeight, 60)), aspect: aspect)
        applyCamera()
    }

    private func applyCamera() {
        let p = orbit.position
        cameraNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
        cameraNode.look(at: SCNVector3(Float(orbit.target.x), Float(orbit.target.y), Float(orbit.target.z)),
                        up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
    }

    // MARK: Plateau

    private func syncBed(_ bed: SceneBed) {
        let printerModel = model.baseConfig["printer_model"] ?? ""
        let signature = "\(bed.shape)|\(bed.maxHeight)|\(printerModel)"
        guard signature != bedSignature else { return }
        let first = bedSignature.isEmpty
        bedSignature = signature
        bedNode.childNodes.forEach { $0.removeFromParentNode() }

        // surface
        let path = UIBezierPath()
        for (i, p) in bed.shape.enumerated() {
            let point = CGPoint(x: p[0], y: p[1])
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 1)
        let surface = SCNMaterial()
        surface.diffuse.contents = UIColor(white: 0.24, alpha: 1)
        surface.lightingModel = .lambert
        shape.materials = [surface]
        let surfaceNode = SCNNode(geometry: shape)
        surfaceNode.position = SCNVector3(0, 0, -1.02)
        bedNode.addChildNode(surfaceNode)

        // quadrillage 10 mm (fin) et 50 mm (marqué)
        bedNode.addChildNode(gridNode(bed, step: 10, color: UIColor(white: 1, alpha: 0.10)))
        bedNode.addChildNode(gridNode(bed, step: 50, color: UIColor(white: 1, alpha: 0.28)))

        // volume d'impression
        bedNode.addChildNode(volumeNode(bed))

        // repère à l'origine (X rouge, Y vert)
        bedNode.addChildNode(axisNode(from: Vec3(bed.minX, bed.minY, 0.05), to: Vec3(bed.minX + 30, bed.minY, 0.05), color: .systemRed))
        bedNode.addChildNode(axisNode(from: Vec3(bed.minX, bed.minY, 0.05), to: Vec3(bed.minX, bed.minY + 30, 0.05), color: .systemGreen))

        // socle fourni par le bundle QIDI (centré sur le plateau, sous Z = 0)
        if let base = bedModelNode(printerModel: printerModel) {
            base.position = SCNVector3(Float((bed.minX + bed.maxX) / 2), Float((bed.minY + bed.maxY) / 2), -0.15)
            bedNode.addChildNode(base)
        }
        if first { frameBed() }
    }

    private func lineNode(_ points: [SCNVector3], color: UIColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: points)
        let element = SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .line)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func gridNode(_ bed: SceneBed, step: Double, color: UIColor) -> SCNNode {
        var points: [SCNVector3] = []
        var x = (bed.minX / step).rounded(.up) * step
        while x <= bed.maxX + 1e-6 {
            points += [SCNVector3(Float(x), Float(bed.minY), 0.02), SCNVector3(Float(x), Float(bed.maxY), 0.02)]
            x += step
        }
        var y = (bed.minY / step).rounded(.up) * step
        while y <= bed.maxY + 1e-6 {
            points += [SCNVector3(Float(bed.minX), Float(y), 0.02), SCNVector3(Float(bed.maxX), Float(y), 0.02)]
            y += step
        }
        return lineNode(points, color: color)
    }

    private func volumeNode(_ bed: SceneBed) -> SCNNode {
        let x0 = Float(bed.minX), x1 = Float(bed.maxX), y0 = Float(bed.minY), y1 = Float(bed.maxY), h = Float(bed.maxHeight)
        let corners = [SCNVector3(x0, y0, 0), SCNVector3(x1, y0, 0), SCNVector3(x1, y1, 0), SCNVector3(x0, y1, 0),
                       SCNVector3(x0, y0, h), SCNVector3(x1, y0, h), SCNVector3(x1, y1, h), SCNVector3(x0, y1, h)]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        return lineNode(edges.flatMap { [corners[$0.0], corners[$0.1]] }, color: UIColor(white: 1, alpha: 0.22))
    }

    private func axisNode(from a: Vec3, to b: Vec3, color: UIColor) -> SCNNode {
        lineNode([SCNVector3(Float(a.x), Float(a.y), Float(a.z)), SCNVector3(Float(b.x), Float(b.y), Float(b.z))], color: color)
    }

    private var bedModelCache: [String: SCNGeometry] = [:]

    private func bedModelNode(printerModel: String) -> SCNNode? {
        guard !printerModel.isEmpty else { return nil }
        let geometry: SCNGeometry
        if let cached = bedModelCache[printerModel] {
            geometry = cached
        } else {
            // « <modèle>_bed.stl » (la casse de l'extension varie dans le bundle)
            guard let dir = Bundle.main.resourceURL?.appendingPathComponent("qidi/profiles/QIDITechnology"),
                  let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                  let match = files.first(where: { $0.lowercased() == "\(printerModel)_bed.stl".lowercased() }),
                  let mesh = try? STLLoader.load(url: dir.appendingPathComponent(match)) else { return nil }
            geometry = STLLoader.geometry(from: mesh, color: UIColor(white: 0.12, alpha: 1))
            bedModelCache[printerModel] = geometry
        }
        return SCNNode(geometry: geometry)
    }

    // MARK: Objets

    private static let normalColor = UIColor(red: 0.98, green: 0.69, blue: 0.25, alpha: 1)
    private static let selectedColor = UIColor(red: 0.30, green: 0.78, blue: 0.45, alpha: 1)
    private static let outsideColor = UIColor(red: 0.90, green: 0.25, blue: 0.25, alpha: 1)

    private func geometry(for id: UInt64) -> SCNGeometry? {
        guard let triangles = model.meshes[id], !triangles.isEmpty else { return nil }
        if let cached = geometries[id], cached.count == triangles.count { return cached.geometry }
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(triangles.count / 3)
        for i in stride(from: 0, to: triangles.count - 2, by: 3) {
            vertices.append(SIMD3(triangles[i], triangles[i + 1], triangles[i + 2]))
        }
        let geometry = STLLoader.geometry(from: STLMesh(vertices: vertices), color: Self.normalColor)
        geometries[id] = (triangles.count, geometry)
        return geometry
    }

    private func color(selected: Bool, outside: Bool) -> UIColor {
        outside ? Self.outsideColor : (selected ? Self.selectedColor : Self.normalColor)
    }

    private func syncObjects(_ scene: SceneInfo?, selection: Set<UInt64>) {
        var live = Set<String>()
        for object in scene?.objects ?? [] {
            guard let base = geometry(for: object.id) else { continue }
            for (index, instance) in object.instances.enumerated() {
                let key = "\(object.id)#\(index)"
                live.insert(key)
                let node: SCNNode
                if let existing = instanceNodes[key], existing.geometry != nil {
                    node = existing
                } else {
                    node = SCNNode()
                    node.name = key
                    instanceNodes[key] = node
                    objectsNode.addChildNode(node)
                }
                // une copie de géométrie partage les sommets mais a son propre matériau (couleur)
                if node.geometry == nil || (node.geometry?.sources.first !== base.sources.first) {
                    node.geometry = base.copy() as? SCNGeometry
                    node.geometry?.materials = [base.firstMaterial?.copy() as? SCNMaterial ?? SCNMaterial()]
                }
                node.geometry?.firstMaterial?.diffuse.contents = color(selected: selection.contains(object.id), outside: instance.outside)
                node.simdTransform = Self.simdMatrix(instance.matrix)
                syncModifiers(of: object, on: node, selected: selection.contains(object.id))
            }
        }
        for (key, node) in instanceNodes where !live.contains(key) {
            node.removeFromParentNode()
            instanceNodes[key] = nil
        }
        for id in geometries.keys where model.meshes[id] == nil { geometries[id] = nil }
    }

    /// Modificateurs et bloqueurs / forceurs de supports : volumes translucides fils de l'instance.
    private func syncModifiers(of object: SceneObject, on node: SCNNode, selected: Bool) {
        node.childNodes.filter { $0.name?.hasPrefix("mod#") == true }.forEach { $0.removeFromParentNode() }
        for volume in object.modifiers {
            let shape: SCNGeometry
            switch volume.name {
            case "cylinder": shape = SCNCylinder(radius: 0.5, height: 1)
            case "sphere": shape = SCNSphere(radius: 0.5)
            default: shape = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
            }
            let material = SCNMaterial()
            let tint: UIColor
            switch volume.kind {
            case "blocker": tint = .systemRed
            case "enforcer": tint = .systemGreen
            default: tint = .systemBlue
            }
            material.diffuse.contents = tint.withAlphaComponent(selected ? 0.45 : 0.30)
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            shape.materials = [material]
            let child = SCNNode(geometry: shape)
            // SCNCylinder a son axe selon Y ; celui du moteur est selon Z.
            if volume.name == "cylinder" { child.eulerAngles = SCNVector3(Float.pi / 2, 0, 0) }
            let holder = SCNNode()
            holder.name = "mod#\(volume.id)"
            holder.position = SCNVector3(Float(volume.offset[0]), Float(volume.offset[1]), Float(volume.offset[2]))
            // taille et position sont dans le repère de l'objet : le nœud d'instance applique le reste
            holder.scale = SCNVector3(Float(volume.size[0]), Float(volume.size[1]), Float(volume.size[2]))
            holder.addChildNode(child)
            node.addChildNode(holder)
        }
    }

    /// Plan de coupe : rectangle translucide à travers l'objet visé.
    private func syncCutPlane(_ scene: SceneInfo?, plane: CutPlane?) {
        cutNode.childNodes.forEach { $0.removeFromParentNode() }
        guard let plane,
              let inst = scene?.objects.first(where: { $0.id == plane.objectID })?.instances.first else { return }
        let size = inst.size
        let margin = 12.0
        let center = plane.point(in: inst)
        let geometry: SCNPlane
        let node: SCNNode
        switch plane.axis {
        case .z:
            geometry = SCNPlane(width: size[0] + margin, height: size[1] + margin)
            node = SCNNode(geometry: geometry)
        case .x:
            geometry = SCNPlane(width: size[1] + margin, height: size[2] + margin)
            node = SCNNode(geometry: geometry)
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, Float.pi / 2)   // normale vers +X
        case .y:
            geometry = SCNPlane(width: size[0] + margin, height: size[2] + margin)
            node = SCNNode(geometry: geometry)
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)   // normale vers -Y (double face)
        }
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.35)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        node.position = SCNVector3(Float(center[0]), Float(center[1]), Float(center[2]))
        cutNode.addChildNode(node)
    }

    static func simdMatrix(_ m: [Double]) -> simd_float4x4 {
        guard m.count == 16 else { return matrix_identity_float4x4 }
        func col(_ i: Int) -> SIMD4<Float> { SIMD4(Float(m[i]), Float(m[i + 1]), Float(m[i + 2]), Float(m[i + 3])) }
        return simd_float4x4(columns: (col(0), col(4), col(8), col(12)))
    }

    // MARK: Picking

    private func viewSize() -> SIMD2<Double> {
        let b = view?.bounds ?? .zero
        return SIMD2(Double(max(b.width, 1)), Double(max(b.height, 1)))
    }

    private func ray(at point: CGPoint) -> Ray {
        orbit.ray(at: SIMD2(Double(point.x), Double(point.y)), viewSize: viewSize())
    }

    /// Objet touché par le rayon : boîte d'abord (rapide), puis triangles (précis).
    private func pickObject(_ ray: Ray) -> (id: UInt64, instance: Int, distance: Double, boxMin: Vec3, boxMax: Vec3)? {
        var best: (UInt64, Int, Double, Vec3, Vec3)?
        for object in model.scene?.objects ?? [] {
            for (index, instance) in object.instances.enumerated() {
                let lo = Vec3(instance.min[0], instance.min[1], instance.min[2])
                let hi = Vec3(instance.max[0], instance.max[1], instance.max[2])
                guard Picking.intersect(ray, boxMin: lo, boxMax: hi) != nil else { continue }
                var distance = Picking.intersect(ray, boxMin: lo, boxMax: hi) ?? 0
                if let triangles = model.meshes[object.id],
                   let hit = Picking.pickTriangle(ray, localTriangles: triangles, matrix: instance.matrix) {
                    distance = hit.distance
                } else if model.meshes[object.id] != nil {
                    continue   // la boîte est touchée, pas la surface
                }
                if best == nil || distance < best!.2 { best = (object.id, index, distance, lo, hi) }
            }
        }
        return best.map { (id: $0.0, instance: $0.1, distance: $0.2, boxMin: $0.3, boxMax: $0.4) }
    }

    // MARK: Gestes

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let r = ray(at: g.location(in: view))
        if model.layOnFaceMode, let id = model.selectedObjectID,
           let object = model.scene?.objects.first(where: { $0.id == id }),
           let instance = object.instances.first,
           let triangles = model.meshes[id],
           let hit = Picking.pickTriangle(r, localTriangles: triangles, matrix: instance.matrix) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            model.layOnFace(objectID: id, triangle: hit.index)
            return
        }
        // ⌘ ou ⇧ (clavier matériel) ou mode « sélection multiple » : ajoute / retire de la sélection
        let additive = model.multiSelectMode || g.modifierFlags.contains(.command) || g.modifierFlags.contains(.shift)
        if let hit = pickObject(r) {
            UISelectionFeedbackGenerator().selectionChanged()
            if additive { model.toggleSelection(hit.id) } else { model.selectedObjectID = hit.id }
        } else if !additive {
            model.selectedObjectID = nil
            model.layOnFaceMode = false
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        frameBed()
    }

    @objc private func handleOneFinger(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastPan = .zero
            let r = ray(at: g.location(in: view))
            if let hit = pickObject(r),
               let object = model.scene?.objects.first(where: { $0.id == hit.id }),
               hit.instance < object.instances.count {
                let point = r.origin + r.direction * hit.distance
                // Un objet de la sélection multiple entraîne tout le groupe ; sinon il devient la sélection.
                if !(model.hasMultipleSelected && model.isSelected(hit.id)) { model.selectedObjectID = hit.id }
                lastSelection = model.selectedObjectIDs
                wasOutsideDuringDrag = object.instances[hit.instance].outside
                var movers: [Mover] = []
                for member in model.selectedObjects {
                    for (index, instance) in member.instances.enumerated() {
                        guard let node = instanceNodes["\(member.id)#\(index)"] else { continue }
                        movers.append(Mover(id: member.id, instance: index, startMatrix: node.simdTransform,
                                            startOffset: instance.offset,
                                            boxMin: Vec3(instance.min[0], instance.min[1], instance.min[2]),
                                            boxMax: Vec3(instance.max[0], instance.max[1], instance.max[2])))
                    }
                }
                drag = .objects(movers: movers, startHit: point, planeZ: point.z)
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                drag = .orbit
            }
        case .changed:
            let t = g.translation(in: view)
            let dx = Double(t.x - lastPan.x), dy = Double(t.y - lastPan.y)
            lastPan = t
            switch drag {
            case .some(.objects(let movers, let startHit, let planeZ)):
                guard let hit = Picking.intersect(ray(at: g.location(in: view)), planeZ: planeZ) else { return }
                let delta = hit - startHit
                var anyOutside = false
                for mover in movers {
                    var m = mover.startMatrix
                    m.columns.3.x += Float(delta.x)
                    m.columns.3.y += Float(delta.y)
                    let node = instanceNodes["\(mover.id)#\(mover.instance)"]
                    node?.simdTransform = m
                    if let bed = model.scene?.bed {
                        let outside = BedBounds.isOutside(min: mover.boxMin + Vec3(delta.x, delta.y, 0),
                                                          max: mover.boxMax + Vec3(delta.x, delta.y, 0), bed: bed)
                        anyOutside = anyOutside || outside
                        node?.geometry?.firstMaterial?.diffuse.contents = color(selected: true, outside: outside)
                    }
                }
                if anyOutside != wasOutsideDuringDrag {
                    wasOutsideDuringDrag = anyOutside
                    UIImpactFeedbackGenerator(style: anyOutside ? .rigid : .soft).impactOccurred()
                }
            case .some(.orbit):
                orbit.orbit(deltaX: dx, deltaY: dy)
                applyCamera()
            case .none:
                break
            }
        case .ended, .cancelled, .failed:
            if case .some(.objects(let movers, _, _)) = drag {
                var changes: [SlicerModel.TransformChange] = []
                for mover in movers {
                    guard let node = instanceNodes["\(mover.id)#\(mover.instance)"] else { continue }
                    let m = node.simdTransform
                    let dx = Double(m.columns.3.x - mover.startMatrix.columns.3.x)
                    let dy = Double(m.columns.3.y - mover.startMatrix.columns.3.y)
                    if abs(dx) > 1e-4 || abs(dy) > 1e-4 {
                        changes.append(SlicerModel.TransformChange(
                            objectID: mover.id, instance: mover.instance,
                            offset: [mover.startOffset[0] + dx, mover.startOffset[1] + dy, mover.startOffset[2]]))
                    }
                }
                // validé auprès du moteur ; l'état moteur revient ensuite dans `scene`
                if !changes.isEmpty { model.applyTransforms(changes) }
            }
            drag = nil
            // La vue garde sa position jusqu'à ce que le moteur ait validé la transformation :
            // `lastScene = nil` force la resynchronisation à la prochaine publication du modèle
            // (sans retour en arrière visible entre-temps).
            lastScene = nil
        default:
            break
        }
    }

    @objc private func handleTwoFinger(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let t = g.translation(in: view)
        orbit.pan(deltaX: Double(t.x), deltaY: Double(t.y), viewHeight: Double(view?.bounds.height ?? 1))
        g.setTranslation(.zero, in: view)
        applyCamera()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        orbit.zoom(scale: Double(g.scale))
        g.scale = 1
        applyCamera()
    }

    @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
        guard let id = model.selectedObjectID,
              let object = model.scene?.objects.first(where: { $0.id == id }),
              let instance = object.instances.first,
              let node = instanceNodes["\(id)#0"] else { return }
        switch g.state {
        case .began:
            rotationStart = (id, node.simdTransform, instance.rotationDeg[2])
        case .changed:
            guard let start = rotationStart else { return }
            // Vu de dessus, le sens horaire à l'écran est un angle Z négatif dans le monde.
            let delta = -Float(g.rotation)
            let rz = simd_float4x4(simd_quatf(angle: delta, axis: SIMD3(0, 0, 1)))
            var m = rz * start.matrix
            m.columns.3 = start.matrix.columns.3   // la rotation se fait autour de l'origine de l'objet
            node.simdTransform = m
        case .ended, .cancelled:
            guard let start = rotationStart else { return }
            rotationStart = nil
            let degrees = -Double(g.rotation) * 180 / .pi
            let newZ = Snapping.snapAngle(start.rotationZ + degrees)
            var rotation = instance.rotationDeg
            rotation[2] = newZ
            model.transform(objectID: id, rotationDeg: rotation, dropToBed: true)
            lastScene = nil
        default:
            break
        }
    }
}

// MARK: - Menu contextuel (appui long / clic droit)

extension BedSceneCoordinator: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let hit = pickObject(ray(at: location)) else { return nil }
        let model = self.model
        // Un objet hors de la sélection devient la sélection ; un objet du groupe garde le groupe.
        if !model.isSelected(hit.id) { model.selectedObjectID = hit.id }
        let group = model.hasMultipleSelected
        let id = hit.id

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var edit: [UIMenuElement] = [
                UIAction(title: L10n.t("Dupliquer"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                    model.duplicateSelected()
                },
                UIAction(title: L10n.t("Poser sur le plateau"), image: UIImage(systemName: "arrow.down.to.line")) { _ in
                    model.dropSelectedToBed()
                },
                UIAction(title: L10n.t("Orientation d'origine"), image: UIImage(systemName: "arrow.counterclockwise")) { _ in
                    model.resetRotationOfSelection()
                },
            ]
            if !group {
                edit.insert(UIAction(title: L10n.t("Poser sur une face"),
                                     image: UIImage(systemName: "square.3.layers.3d.down.forward")) { _ in
                    model.layOnFaceMode = true
                }, at: 1)
            }

            var tools: [UIMenuElement] = []
            if !group {
                tools = [
                    UIAction(title: L10n.t("Couper…"), image: UIImage(systemName: "scissors")) { _ in model.beginCut() },
                    UIAction(title: L10n.t("Simplifier le maillage…"),
                             image: UIImage(systemName: "square.3.layers.3d.down.right")) { _ in
                        model.activeTool = .simplify(id)
                    },
                    UIAction(title: L10n.t("Réglages de l'objet…"), image: UIImage(systemName: "slider.horizontal.3")) { _ in
                        model.activeTool = .settings(id)
                    },
                ]
            }

            let selection: [UIMenuElement] = [
                UIAction(title: L10n.t("Tout sélectionner"), image: UIImage(systemName: "square.dashed.inset.filled")) { _ in
                    model.selectAll()
                },
                UIAction(title: L10n.t("Organiser"), image: UIImage(systemName: "square.grid.3x3.square")) { _ in
                    model.arrange()
                },
            ]
            let delete = UIAction(title: L10n.t("Supprimer"), image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { _ in model.deleteSelected() }

            var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: edit)]
            if !tools.isEmpty { children.append(UIMenu(options: .displayInline, children: tools)) }
            children.append(UIMenu(options: .displayInline, children: selection))
            children.append(UIMenu(options: .displayInline, children: [delete]))
            return UIMenu(children: children)
        }
    }
}
