//
//  QIDIBox.swift
//  QIDI Box (changeur de filaments, jusqu'à 16 emplacements = 4 boîtes de 4 bobines) :
//  noms des emplacements, commandes Klipper qui associent chaque extrudeur du G-code à un
//  emplacement, lecture de l'association actuelle.
//
//  Reprend ce que fait QIDISlicer desktop avant de lancer une impression (Plater, envoi
//  vers l'imprimante) : `SAVE_VARIABLE VARIABLE=enable_box VALUE=1|0`, puis pour chaque
//  extrudeur `SAVE_VARIABLE VARIABLE=value_t<n> VALUE=\"'slot<k>'\"`.
//  La lecture automatique du contenu du Box (couleur, matière) passe par un module réseau
//  fermé du bureau, absent des sources : ici les emplacements se règlent à la main.
//  Pur Foundation : testé sous Linux.
//

import Foundation

enum QIDIBox {
    static let slotCount = 16

    /// 0 → « 1A », 3 → « 1D », 4 → « 2A »… (boîte 1–4, bobine A–D), comme le bureau.
    static func trayName(_ slot: Int) -> String {
        guard (0..<slotCount).contains(slot) else { return "?" }
        return "\(slot / 4 + 1)\(Character(UnicodeScalar(UInt8(65 + slot % 4))))"
    }

    static var allTrays: [(slot: Int, name: String)] { (0..<slotCount).map { ($0, trayName($0)) } }

    /// Emplacement par défaut de chaque extrudeur : 1A, 1B, 1C…
    static func defaultSlots(count: Int) -> [Int] { (0..<max(count, 0)).map { $0 % slotCount } }

    /// Commandes G-code à envoyer à l'imprimante avant de démarrer : activation du Box, puis
    /// l'emplacement de chaque extrudeur (T0, T1…).
    static func activationCommands(slots: [Int], enabled: Bool) -> [String] {
        var commands = ["SAVE_VARIABLE VARIABLE=enable_box VALUE=\(enabled ? 1 : 0)"]
        guard enabled else { return commands }
        for (tool, slot) in slots.enumerated() where (0..<slotCount).contains(slot) {
            commands.append("SAVE_VARIABLE VARIABLE=value_t\(tool) VALUE=\\\"'slot\(slot)'\\\"")
        }
        return commands
    }

    struct Variables: Equatable {
        var enabled: Bool
        /// Emplacement associé à chaque outil (nil = inconnu), de T0 à T15.
        var slots: [Int?]
    }

    /// Lit `save_variables.variables` dans la réponse de `/printer/objects/query?save_variables` :
    /// `enable_box` (0/1) et `value_t<n>` (`'slot3'`).
    static func parseVariables(_ data: Data) -> Variables? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let status = result["status"] as? [String: Any],
              let saved = status["save_variables"] as? [String: Any],
              let variables = saved["variables"] as? [String: Any] else { return nil }
        func int(_ value: Any?) -> Int? {
            if let n = value as? Int { return n }
            if let d = value as? Double { return Int(d) }
            if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        var slots = [Int?](repeating: nil, count: slotCount)
        for tool in 0..<slotCount {
            guard let text = variables["value_t\(tool)"] as? String else { continue }
            let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
            slots[tool] = Int(digits)
        }
        return Variables(enabled: (int(variables["enable_box"]) ?? 0) != 0, slots: slots)
    }
}
