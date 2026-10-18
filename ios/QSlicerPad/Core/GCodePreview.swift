//
//  GCodePreview.swift
//  Aperçu des trajectoires d'un G-code, couche par couche.
//
//  Objectif : un rendu simple et *borné en mémoire* (un G-code peut faire des
//  centaines de Mo) : on garde des segments 2D (X/Y) par couche, plafonnés, et on
//  affiche la couche sélectionnée (+ les précédentes en filigrane).
//

import Foundation
import SceneKit
import UIKit   // UIColor
import simd

struct GCodePreview {
    struct Layer {
        /// Segments consécutifs : [x0,y0, x1,y1, x0,y0, …] (mètres non convertis).
        var segments: [SIMD2<Float>] = []
        var z: Float = 0
    }

    private(set) var layers: [Layer] = []
    let bounds: (min: SIMD2<Float>, max: SIMD2<Float>)

    /// Parse un G-code en streaming (le fichier n'est jamais chargé entièrement).
    /// - Parameters:
    ///   - maxLayers: nombre de couches conservées (les suivantes sont ignorées).
    static func parse(url: URL, maxLayers: Int = 2000) throws -> GCodePreview {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadNoSuchFile) }
        stream.open()
        defer { stream.close() }

        var layers: [Layer] = []
        var current = Layer()
        var pendingLayerZ: Float?
        var x: Float = 0, y: Float = 0, z: Float = 0
        var absoluteE = true
        var lastE: Float = 0
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()

        func flushLayer() {
            if !current.segments.isEmpty {
                current.z = pendingLayerZ ?? z
                layers.append(current)
                current = Layer()
            }
            pendingLayerZ = nil
        }

        func handle(_ line: Substring) {
            if line.hasPrefix(";LAYER_CHANGE") {
                flushLayer()
                return
            }
            // Le moteur émet la hauteur de couche juste après ;LAYER_CHANGE
            // (« ;Z:0.2 »). C'est plus fiable que de suivre les mouvements Z
            // (le générateur fait des sauts de Z entre les couches).
            if line.hasPrefix(";Z:"), let value = Float(line.dropFirst(3)) {
                pendingLayerZ = value
                return
            }
            guard line.hasPrefix("G0") || line.hasPrefix("G1") else {
                if line.hasPrefix("G90") { absoluteE = true }
                else if line.hasPrefix("G91") { absoluteE = false }
                else if line.hasPrefix("G92") { lastE = 0 }
                return
            }
            var nx = x, ny = y, nz = z
            var e: Float?
            for token in line.split(separator: " ") {
                guard let first = token.first else { continue }
                let value = Float(token.dropFirst())
                switch first {
                case "X": if let v = value { nx = v }
                case "Y": if let v = value { ny = v }
                case "Z": if let v = value { nz = v }
                case "E": e = value
                default: break
                }
            }
            // On ne trace que les mouvements avec extrusion positive.
            var extruding = false
            if let e {
                let delta = absoluteE ? (e - lastE) : e
                extruding = delta > 0.0001
                lastE = absoluteE ? e : (lastE + e)
            }
            if extruding && (nx != x || ny != y) && layers.count < maxLayers {
                current.segments.append(SIMD2<Float>(x, y))
                current.segments.append(SIMD2<Float>(nx, ny))
                lo = simd_min(lo, SIMD2<Float>(nx, ny))
                hi = simd_max(hi, SIMD2<Float>(nx, ny))
            }
            x = nx; y = ny; z = nz
        }

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            pending.append(buffer, count: read)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending = pending[(newline + 1)...]
                if let text = String(data: lineData, encoding: .utf8) {
                    handle(Substring(text))
                }
            }
        }
        if let text = String(data: pending, encoding: .utf8) { handle(Substring(text)) }
        flushLayer()

        let bounds = layers.isEmpty ? (SIMD2<Float>.zero, SIMD2<Float>.zero) : (lo, hi)
        return GCodePreview(layers: layers, bounds: bounds)
    }

    private init(layers: [Layer], bounds: (min: SIMD2<Float>, max: SIMD2<Float>)) {
        self.layers = layers
        self.bounds = bounds
    }

    /// Géométrie SceneKit des couches 0…`upTo` (filigrane + couche courante).
    func geometry(upTo layerIndex: Int, color: UIColor = .systemOrange) -> SCNGeometry? {
        guard !layers.isEmpty else { return nil }
        let last = min(max(layerIndex, 0), layers.count - 1)
        var points: [SCNVector3] = []
        let total = layers.prefix(last + 1).reduce(0) { $0 + $1.segments.count }
        points.reserveCapacity(total)
        for (index, layer) in layers.enumerated() where index <= last {
            let z = layer.z
            for p in layer.segments {
                points.append(SCNVector3(p.x, p.y, z))
            }
        }
        guard !points.isEmpty else { return nil }
        let source = SCNGeometrySource(vertices: points)
        let indices = (0..<Int32(points.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }
}
