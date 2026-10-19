//
//  BonjourBrowser.swift
//  Imprimantes annoncées sur le réseau local (Bonjour / mDNS) : Moonraker publie
//  `_moonraker._tcp`, et l'interface web `_http._tcp`. On ne retient que les adresses IPv4 ;
//  PrinterDiscovery les sonde ensuite sur /server/info pour confirmer que c'est un Moonraker.
//  Nécessite NSLocalNetworkUsageDescription et NSBonjourServices (Info.plist).
//

import Foundation
import Network

enum BonjourBrowser {
    /// Écoute `seconds` secondes et retourne les adresses IPv4 résolues.
    static func browse(seconds: TimeInterval) async -> [String] {
        await withCheckedContinuation { continuation in
            BonjourSession().run(seconds: seconds) { continuation.resume(returning: $0) }
        }
    }
}

/// Une écoute ; tout se passe sur sa file série.
private final class BonjourSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qsid.bonjour")
    private var browsers: [NWBrowser] = []
    private var connections: [NWConnection] = []
    private var hosts: [String] = []
    private var pending: [NWEndpoint: Bool] = [:]

    func run(seconds: TimeInterval, completion: @escaping ([String]) -> Void) {
        queue.async {
            for type in ["_moonraker._tcp", "_http._tcp"] {
                let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    for result in results { self?.resolve(result.endpoint) }
                }
                browser.start(queue: self.queue)
                self.browsers.append(browser)
            }
        }
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            browsers.forEach { $0.cancel() }
            connections.forEach { $0.cancel() }
            browsers = []
            connections = []
            completion(hosts)
        }
    }

    /// Une connexion TCP vers le service donne l'adresse réelle (le nom Bonjour n'est pas une IP).
    private func resolve(_ endpoint: NWEndpoint) {
        guard pending[endpoint] == nil else { return }
        pending[endpoint] = true
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else { return }
            if let remote = connection.currentPath?.remoteEndpoint,
               case .hostPort(let host, _) = remote, case .ipv4(let address) = host {
                // « 192.168.1.42%en0 » → « 192.168.1.42 »
                let text = "\(address)".split(separator: "%").first.map(String.init) ?? ""
                if !text.isEmpty, self?.hosts.contains(text) == false { self?.hosts.append(text) }
            }
            connection.cancel()
        }
        connection.start(queue: queue)
    }
}
