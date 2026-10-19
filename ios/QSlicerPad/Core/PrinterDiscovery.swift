//
//  PrinterDiscovery.swift
//  Découverte des imprimantes Klipper (Moonraker) du réseau local : balayage du sous-réseau
//  de chaque interface Wi-Fi / Ethernet — chaque adresse est sondée sur /server/info, ce qui
//  distingue un vrai Moonraker d'un autre service. Complété côté app par Bonjour
//  (Model/BonjourBrowser.swift). Pur Foundation : testé sous Linux contre le faux Moonraker.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct DiscoveredPrinter: Equatable, Hashable, Identifiable {
    var host: String
    var port: Int
    /// Nom d'hôte annoncé par l'imprimante (si lisible).
    var hostname: String?
    var klippyState: String?
    var version: String?

    var id: String { "\(host):\(port)" }
    var title: String { hostname.map { $0.isEmpty ? host : $0 } ?? host }
}

enum PrinterDiscovery {
    struct Interface: Equatable {
        var name: String
        var address: String
        var netmask: String
    }

    // MARK: Réseau local

    /// Interfaces IPv4 actives, hors boucle locale (Wi-Fi, Ethernet).
    static func localInterfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var result: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let addr = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let a = ipv4String(addr), let m = ipv4String(mask) else { continue }
            result.append(Interface(name: String(cString: entry.pointee.ifa_name), address: a, netmask: m))
        }
        return result
    }

    private static func ipv4String(_ sockaddrPointer: UnsafePointer<sockaddr>) -> String? {
        sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p -> String? in
            var address = p.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    static func format(_ value: UInt32) -> String {
        "\(value >> 24 & 255).\(value >> 16 & 255).\(value >> 8 & 255).\(value & 255)"
    }

    /// Adresses à sonder dans le sous-réseau de `address`/`netmask` : toutes les adresses
    /// d'hôte sauf la sienne, avec au plus 1022 adresses (un /22) autour de la sienne.
    static func candidateHosts(address: String, netmask: String, limit: Int = 1022) -> [String] {
        guard let ip = parseIPv4(address), let mask = parseIPv4(netmask), mask != 0 else { return [] }
        // masque contigu uniquement (255.255.255.0…) ; sinon on se limite au /24
        let prefix = mask.leadingZeroBitCount == 0 ? mask.nonzeroBitCount : 24
        let contiguous = mask == (prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix))
        let effectivePrefix = contiguous ? max(prefix, 22) : 24
        guard effectivePrefix < 31 else { return [] }
        let hostMask = ~UInt32(0) << UInt32(32 - effectivePrefix)
        let network = ip & hostMask
        let broadcast = network | ~hostMask
        var hosts: [String] = []
        var candidate = network + 1
        while candidate < broadcast, hosts.count < limit {
            if candidate != ip { hosts.append(format(candidate)) }
            candidate += 1
        }
        return hosts
    }

    /// Adresses à sonder sur toutes les interfaces (sans doublon, ordre stable).
    static func allCandidateHosts(interfaces: [Interface] = localInterfaces()) -> [String] {
        var seen = Set<String>()
        return interfaces.flatMap { candidateHosts(address: $0.address, netmask: $0.netmask) }.filter { seen.insert($0).inserted }
    }

    // MARK: Sonde

    /// Réponse de `/server/info` : `{"result": {"moonraker_version": …, "klippy_state": …}}`.
    /// nil si ce n'est pas un Moonraker (autre service, JSON différent).
    static func parseServerInfo(_ data: Data) -> (version: String, klippyState: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let version = result["moonraker_version"] as? String else { return nil }
        return (version, result["klippy_state"] as? String)
    }

    /// Le délai est porté par chaque requête : régler `timeoutIntervalForRequest` sur la session fait
    /// échouer la première requête du processus sous Linux (FoundationNetworking).
    private static func get(_ session: URLSession, _ url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Sonde une adresse : un Moonraker y répond-il ?
    static func probe(host: String, port: Int = 7125, timeout: TimeInterval = 0.8) async -> DiscoveredPrinter? {
        guard let url = URL(string: "http://\(host):\(port)/server/info") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let data = await get(session, url, timeout: timeout), let info = parseServerInfo(data) else { return nil }
        var found = DiscoveredPrinter(host: host, port: port, hostname: nil, klippyState: info.klippyState, version: info.version)
        // nom d'hôte : facultatif, meilleure tentative
        if let infoURL = URL(string: "http://\(host):\(port)/printer/info"),
           let body = await get(session, infoURL, timeout: timeout),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let result = object["result"] as? [String: Any] {
            found.hostname = result["hostname"] as? String
        }
        return found
    }

    /// Sonde `hosts` avec au plus `concurrency` requêtes simultanées. `progress` reçoit (sondées, total).
    /// Retourne les imprimantes trouvées, triées par adresse.
    static func scan(hosts: [String], port: Int = 7125, concurrency: Int = 48, timeout: TimeInterval = 0.8,
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [DiscoveredPrinter] {
        var found: [DiscoveredPrinter] = []
        var done = 0
        await withTaskGroup(of: DiscoveredPrinter?.self) { group in
            var iterator = hosts.makeIterator()
            func next() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask { await probe(host: host, port: port, timeout: timeout) }
                return true
            }
            for _ in 0..<max(1, concurrency) { if !next() { break } }
            while let result = await group.next() {
                done += 1
                if let result { found.append(result) }
                progress?(done, hosts.count)
                if Task.isCancelled { group.cancelAll(); continue }
                _ = next()
            }
        }
        return found.sorted { (parseIPv4($0.host) ?? 0, $0.port) < (parseIPv4($1.host) ?? 0, $1.port) }
    }
}
