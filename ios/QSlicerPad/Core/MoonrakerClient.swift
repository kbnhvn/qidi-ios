//
//  MoonrakerClient.swift
//  Envoi du G-code à une imprimante Klipper (Moonraker) sur le réseau local.
//
//  L'app reste hors ligne pour le slicing : ce client ne parle qu'à l'imprimante
//  que l'utilisateur configure, en HTTP simple (ATS autorise le réseau local).
//  API utilisée (Moonraker) :
//    POST /server/files/upload          (multipart : file, root=gcodes)
//    POST /printer/print/start?filename=
//    GET  /printer/objects/query?print_stats=state&display_status=progress
//

import Foundation

struct MoonrakerConfig: Codable, Equatable {
    var host: String = ""          // ex. 192.168.1.42 ou qidi.local
    var port: Int = 7125
    var apiKey: String = ""        // facultatif (X-Api-Key)

    var isConfigured: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
    var baseURL: URL? {
        var hostPart = host.trimmingCharacters(in: .whitespaces)
        guard !hostPart.isEmpty else { return nil }
        if hostPart.hasPrefix("http://") || hostPart.hasPrefix("https://") {
            if let url = URL(string: hostPart) { return url }
            return nil
        }
        if hostPart.hasSuffix("/") { hostPart.removeLast() }
        return URL(string: "http://\(hostPart):\(port)")
    }
}

enum MoonrakerError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:          return "Aucune imprimante configurée (Réglages → Imprimante)."
        case .badURL:                 return "Adresse d'imprimante invalide."
        case .http(let code, let m):  return "Erreur HTTP \(code) : \(m)"
        case .transport(let m):       return "Réseau : \(m)"
        }
    }
}

struct MoonrakerClient {
    let config: MoonrakerConfig

    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        guard config.isConfigured else { throw MoonrakerError.notConfigured }
        guard let base = config.baseURL else { throw MoonrakerError.badURL }
        guard let url = URL(string: path, relativeTo: base) else { throw MoonrakerError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if !config.apiKey.isEmpty {
            req.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        return req
    }

    /// Envoie un G-code dans `gcodes/` sur l'imprimante.
    func upload(file: URL, filename: String? = nil) async throws {
        let name = filename ?? file.lastPathComponent
        var req = try request("/server/files/upload", method: "POST")
        let boundary = "QSID-" + UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        field("root", "gcodes")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file, options: .mappedIfSafe))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await send(req)
        try Self.validate(response, data)
    }

    /// Démarre l'impression d'un fichier déjà présent dans `gcodes/`.
    func startPrint(filename: String) async throws {
        let escaped = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename
        var req = try request("/printer/print/start?filename=\(escaped)", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(req)
        try Self.validate(response, data)
    }

    /// État lisible de l'imprimante (« printing », progression…).
    func status() async throws -> (state: String, progress: Double) {
        let req = try request("/printer/objects/query?print_stats=state&display_status=progress")
        let (data, response) = try await send(req)
        try Self.validate(response, data)

        // La réponse est { "result": { "status": { "print_stats": {...}, ... } } } :
        // on la lit sans modèle Decodable (deux niveaux de clés dynamiques).
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = object["result"] as? [String: Any],
           let status = result["status"] as? [String: Any] {
            let stats = status["print_stats"] as? [String: Any]
            let display = status["display_status"] as? [String: Any]
            return (stats?["state"] as? String ?? "inconnu",
                    display?["progress"] as? Double ?? 0)
        }
        return ("inconnu", 0)
    }

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw MoonrakerError.transport(error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MoonrakerError.http(http.statusCode, body)
        }
    }
}
