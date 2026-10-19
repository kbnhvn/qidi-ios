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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    /// Envoie un G-code dans `gcodes/` sur l'imprimante. Le corps multipart est écrit sur
    /// disque (un G-code peut peser des centaines de Mo) et envoyé en flux, avec progression.
    func upload(file: URL, filename: String? = nil, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let name = filename ?? file.lastPathComponent
        var req = try request("/server/files/upload", method: "POST")
        let boundary = "QSID-" + UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        try MultipartBody.write(file: file, filename: name, fields: ["root": "gcodes"], boundary: boundary, to: body)
        defer { try? FileManager.default.removeItem(at: body) }

        let delegate = UploadProgress(onProgress)
        do {
            let (data, response) = try await URLSession.shared.upload(for: req, fromFile: body, delegate: delegate)
            try Self.validate(response, data)
        } catch let error as MoonrakerError {
            throw error
        } catch {
            throw MoonrakerError.transport(error.localizedDescription)
        }
    }

    /// Démarre l'impression d'un fichier déjà présent dans `gcodes/`.
    func startPrint(filename: String) async throws {
        let escaped = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename
        var req = try request("/printer/print/start?filename=\(escaped)", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(req)
        try Self.validate(response, data)
    }

    /// État de l'imprimante : état d'impression, progression, fichier, températures.
    func status() async throws -> PrinterStatus {
        let req = try request("/printer/objects/query?print_stats&display_status&extruder&heater_bed")
        let (data, response) = try await send(req)
        try Self.validate(response, data)
        return PrinterStatus.parse(data)
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

/// État lisible d'une imprimante Klipper.
struct PrinterStatus: Equatable {
    var state = "inconnu"
    var progress = 0.0
    var filename = ""
    var nozzle: Double?
    var nozzleTarget: Double?
    var bed: Double?
    var bedTarget: Double?
    var message = ""

    /// Libellé français de l'état Klipper.
    var stateLabel: String {
        switch state {
        case "standby": return "Au repos"
        case "printing": return "Impression en cours"
        case "paused": return "En pause"
        case "complete": return "Terminé"
        case "cancelled": return "Annulé"
        case "error": return "Erreur"
        default: return state
        }
    }

    /// Réponse de `/printer/objects/query` : { "result": { "status": { objet: {…} } } }.
    static func parse(_ data: Data) -> PrinterStatus {
        var out = PrinterStatus()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let status = result["status"] as? [String: Any] else { return out }
        if let stats = status["print_stats"] as? [String: Any] {
            out.state = stats["state"] as? String ?? out.state
            out.filename = stats["filename"] as? String ?? ""
            out.message = stats["message"] as? String ?? ""
        }
        if let display = status["display_status"] as? [String: Any] {
            out.progress = display["progress"] as? Double ?? 0
        }
        if let extruder = status["extruder"] as? [String: Any] {
            out.nozzle = extruder["temperature"] as? Double
            out.nozzleTarget = extruder["target"] as? Double
        }
        if let bed = status["heater_bed"] as? [String: Any] {
            out.bed = bed["temperature"] as? Double
            out.bedTarget = bed["target"] as? Double
        }
        return out
    }
}

/// Corps multipart/form-data écrit sur disque, en flux.
enum MultipartBody {
    static func write(file: URL, filename: String, fields: [String: String], boundary: String, to destination: URL) throws {
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        func put(_ text: String) throws { try out.write(contentsOf: Data(text.utf8)) }

        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        let escaped = filename.replacingOccurrences(of: "\"", with: "%22")
        try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(escaped)\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try put("\r\n--\(boundary)--\r\n")
    }
}

/// Relaie la progression d'envoi d'une tâche URLSession.
final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: (@Sendable (Double) -> Void)?
    init(_ handler: (@Sendable (Double) -> Void)?) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
