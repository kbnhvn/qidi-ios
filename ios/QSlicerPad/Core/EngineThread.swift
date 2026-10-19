//
//  EngineThread.swift
//  Fil d'exécution série dédié au moteur de slicing, avec une grande pile.
//
//  Un thread secondaire de GCD n'a que 512 Ko de pile sous iOS (8 Mo sous macOS / Linux) : le
//  découpage récursif de libslic3r (Arachne, Clipper, arbres de supports…) la dépasse sur des
//  modèles réels, ce qui tue l'app sans message. Ce thread réserve 64 Mo (de la mémoire virtuelle,
//  consommée seulement si elle sert). Les travaux s'exécutent dans l'ordre d'arrivée.
//  Pur Foundation : testé sous Linux.
//

import Foundation

final class EngineThread: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopped = false
    private var thread: Thread?

    /// Pile de 64 Mo par défaut.
    init(name: String, stackSize: Int = 64 * 1024 * 1024) {
        let t = Thread { [weak self] in self?.loop() }
        t.name = name
        t.stackSize = stackSize          // à fixer avant le démarrage
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopped { condition.wait() }
            if jobs.isEmpty && stopped { condition.unlock(); return }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    /// Met un travail en file (exécuté dans l'ordre, un à la fois).
    func async(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Arrête le thread une fois la file vidée (tests).
    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    /// Taille de pile effective du thread courant (octets), pour les tests.
    static var currentStackSize: Int { Thread.current.stackSize }
}
