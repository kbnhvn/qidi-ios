//
//  SliceBreadcrumb.swift
//  Trace de la progression du slicing, écrite au fil de l'eau sur disque. Si l'app est tuée en
//  plein calcul (mémoire, pile, plantage du moteur), le fichier reste : au lancement suivant,
//  l'app peut dire à quelle étape elle s'est arrêtée — le seul indice quand l'app ferme sans
//  message. Supprimé à la fin normale d'un slicing. Pur Foundation : testé sous Linux.
//

import Foundation

final class SliceBreadcrumb: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var last = ""

    init(url: URL) { self.url = url }

    /// Début d'un slicing : repart d'un fichier vide.
    func begin(summary: String) {
        lock.lock(); defer { lock.unlock() }
        last = ""
        try? "début : \(summary)\n".write(to: url, atomically: false, encoding: .utf8)
    }

    /// Note une étape (appelable depuis le thread du moteur) ; les répétitions sont ignorées.
    func note(percent: Int, text: String) {
        lock.lock(); defer { lock.unlock() }
        let line = percent >= 0 ? "\(percent) % — \(text)" : text
        guard !text.isEmpty, text != last, let data = (line + "\n").data(using: .utf8) else { return }
        last = text
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.synchronize()   // sur disque avant la suite : un plantage ne doit pas la perdre
    }

    /// Fin normale (réussite, annulation ou erreur rapportée) : plus rien à signaler.
    func end() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Si un slicing précédent s'est interrompu : sa dernière étape (le fichier est ensuite supprimé).
    func interruptedStage() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let lines = text.split(separator: "\n").map(String.init)
        guard let lastLine = lines.last else { return nil }
        return lines.count == 1 ? "\(lastLine) (avant toute progression)" : lastLine
    }
}
