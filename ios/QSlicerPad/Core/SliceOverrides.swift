//
//  SliceOverrides.swift
//  Options de slicing exposées à l'utilisateur, appliquées *par-dessus* le preset
//  QIDI choisi (elles ont donc la priorité). Volontairement limitées aux réglages
//  qu'on touche vraiment sur tablette : supports, adhérence, remplissage, qualité,
//  solides, température.
//

import Foundation

struct SliceOverrides: Codable, Equatable {
    /// Si false, rien n'est appliqué : le preset QIDI est utilisé tel quel.
    var enabled = false

    // Adhérence
    enum Adhesion: String, Codable, CaseIterable, Identifiable {
        case none, brim, raft
        var id: String { rawValue }
    }
    var adhesion: Adhesion = .none
    var brimWidth: Double = 5      // mm (utilisé si adhesion == .brim)
    var raftLayers: Int = 3        // utilisé si adhesion == .raft

    // Supports
    var supports = false
    var supportThreshold: Double = 30   // degrés : au-delà, on supporte

    // Remplissage / qualité / solides
    var infillDensity: Int = 15         // %
    var layerHeight: Double = 0         // 0 = garder la hauteur du preset
    var perimeters: Int = 0             // 0 = garder le preset

    // Température (delta appliqué à la buse, pour ne pas casser un profil ABS)
    var nozzleDelta: Int = 0            // °C

    static let layerHeights: [Double] = [0, 0.08, 0.12, 0.16, 0.2, 0.24, 0.28]

    /// Entrées .ini à ajouter à la configuration résolue du preset.
    func configEntries(basedOn base: [String: String]) -> [String: String] {
        guard enabled else { return [:] }
        var out: [String: String] = [:]

        // Adhérence : un seul des deux mécanismes à la fois.
        switch adhesion {
        case .none:
            out["brim_width"] = "0"
            out["raft_layers"] = "0"
        case .brim:
            out["brim_width"] = String(format: "%.1f", brimWidth)
            out["raft_layers"] = "0"
        case .raft:
            out["brim_width"] = "0"
            out["raft_layers"] = String(raftLayers)
        }

        out["support_material"] = supports ? "1" : "0"
        if supports {
            out["support_material_auto"] = "1"
            out["support_material_threshold"] = String(Int(supportThreshold))
        }

        out["fill_density"] = "\(infillDensity)%"
        if layerHeight > 0 { out["layer_height"] = String(format: "%.2f", layerHeight) }
        if perimeters > 0 { out["perimeters"] = String(perimeters) }

        if nozzleDelta != 0,
           let baseTemp = Double(base["temperature"] ?? ""),
           let baseFirst = Double(base["first_layer_temperature"] ?? "") {
            out["temperature"] = String(Int(baseTemp) + nozzleDelta)
            out["first_layer_temperature"] = String(Int(baseFirst) + nozzleDelta)
        }
        return out
    }

    /// Résumé lisible pour l'écran principal.
    var summary: String? {
        guard enabled else { return nil }
        var parts: [String] = []
        if supports { parts.append("supports") }
        switch adhesion {
        case .none: break
        case .brim: parts.append(String(format: "brim %.0f mm", brimWidth))
        case .raft: parts.append("raft \(raftLayers) couches")
        }
        parts.append("remplissage \(infillDensity) %")
        if layerHeight > 0 { parts.append(String(format: "couche %.2f mm", layerHeight)) }
        if perimeters > 0 { parts.append("\(perimeters) périmètres") }
        if nozzleDelta != 0 { parts.append(String(format: "buse %+d °C", nozzleDelta)) }
        return parts.joined(separator: " · ")
    }
}
