//
//  ThumbnailRenderer.swift
//  Vignettes du G-code (aperçu affiché par l'écran de l'imprimante). Le moteur
//  encode (QIDI/PNG, selon `thumbnails` du preset) ; l'hôte fournit les pixels :
//  rendu SceneKit hors écran de la scène, vue isométrique cadrée sur les objets.
//

import Foundation
import SceneKit
import UIKit
import Metal
import simd

final class ThumbnailProvider {
    struct Item {
        let triangles: [Float]
        /// Une matrice monde par instance.
        let matrices: [simd_float4x4]
    }

    private let items: [Item]
    private let boundsMin: Vec3
    private let boundsMax: Vec3

    init(items: [Item], boundsMin: Vec3, boundsMax: Vec3) {
        self.items = items
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
    }

    /// Rend `width`×`height` pixels RGBA (lignes de haut en bas). SceneKit rend sur le
    /// thread principal : le thread de slicing l'attend (le principal n'attend jamais le moteur).
    func render(width: Int, height: Int) -> [UInt8]? {
        var result: [UInt8]?
        if Thread.isMainThread {
            result = renderOnMain(width: width, height: height)
        } else {
            DispatchQueue.main.sync { result = self.renderOnMain(width: width, height: height) }
        }
        return result
    }

    private func renderOnMain(width: Int, height: Int) -> [UInt8]? {
        guard !items.isEmpty, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.13, alpha: 1)

        let color = UIColor(red: 0.98, green: 0.69, blue: 0.25, alpha: 1)
        for item in items {
            var vertices: [SIMD3<Float>] = []
            vertices.reserveCapacity(item.triangles.count / 3)
            for i in stride(from: 0, to: item.triangles.count - 2, by: 3) {
                vertices.append(SIMD3(item.triangles[i], item.triangles[i + 1], item.triangles[i + 2]))
            }
            let geometry = STLLoader.geometry(from: STLMesh(vertices: vertices), color: color)
            for matrix in item.matrices {
                let node = SCNNode(geometry: geometry)
                node.simdTransform = matrix
                scene.rootNode.addChildNode(node)
            }
        }

        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        scene.rootNode.addChildNode(sun)

        var orbit = OrbitCamera.preset(.isometric, target: .zero, distance: 300)
        orbit.frame(min: boundsMin, max: boundsMax, aspect: Double(width) / Double(max(height, 1)))
        let camera = SCNCamera()
        camera.fieldOfView = orbit.fovDegrees
        camera.zNear = 1
        camera.zFar = 8000
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let p = orbit.position
        cameraNode.position = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
        scene.rootNode.addChildNode(cameraNode)
        cameraNode.look(at: SCNVector3(Float(orbit.target.x), Float(orbit.target.y), Float(orbit.target.z)),
                        up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
        return Self.rgba(from: image, width: width, height: height)
    }

    private static func rgba(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
