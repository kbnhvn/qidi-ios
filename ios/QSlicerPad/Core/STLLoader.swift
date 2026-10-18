//
//  STLLoader.swift
//  Lecture d'un STL (binaire ou ASCII) et construction d'une géométrie SceneKit.
//
//  Le visualiseur passe par un STL même pour les autres formats : le moteur sait
//  exporter n'importe quel modèle supporté vers un STL binaire (qsid_export_stl),
//  ce qui évite d'écrire des lecteurs 3MF/OBJ/AMF côté Swift.
//

import Foundation
import SceneKit
import UIKit   // UIColor
import simd

enum STLLoaderError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: return "STL illisible."
        case .empty:      return "Le STL ne contient aucun triangle."
        }
    }
}

struct STLMesh {
    /// Triangles, 3 sommets par facette.
    var vertices: [SIMD3<Float>]

    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = vertices.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for v in vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }
}

enum STLLoader {
    static func load(url: URL) throws -> STLMesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count >= 84 {
            let count = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 80, as: UInt32.self) })
            if data.count >= 84 + count * 50 {
                return try loadBinary(data, triangleCount: count)
            }
        }
        return try loadASCII(data)
    }

    private static func loadBinary(_ data: Data, triangleCount: Int) throws -> STLMesh {
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(triangleCount * 3)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<triangleCount {
                // 50 octets par facette : normale (12) + 3 sommets (36) + attribut (2)
                let offset = 84 + i * 50 + 12
                for v in 0..<3 {
                    let p = base.advanced(by: offset + v * 12)
                        .assumingMemoryBound(to: Float.self)
                    vertices.append(SIMD3<Float>(p[0], p[1], p[2]))
                }
            }
        }
        guard !vertices.isEmpty else { throw STLLoaderError.empty }
        return STLMesh(vertices: vertices)
    }

    private static func loadASCII(_ data: Data) throws -> STLMesh {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw STLLoaderError.unreadable
        }
        var vertices: [SIMD3<Float>] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("vertex") else { continue }
            let parts = trimmed.split(separator: " ")
            guard parts.count >= 4,
                  let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else { continue }
            vertices.append(SIMD3<Float>(x, y, z))
        }
        guard !vertices.isEmpty else { throw STLLoaderError.empty }
        return STLMesh(vertices: vertices)
    }

    /// Géométrie SceneKit (triangles) à partir d'un maillage.
    static func geometry(from mesh: STLMesh, color: UIColor = .systemOrange) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: mesh.vertices)
        let indices = (0..<Int32(mesh.vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        let material = SCNMaterial()
        material.diffuse.contents = color
        material.isDoubleSided = true
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.65
        material.metalness.contents = 0.05

        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }
}
