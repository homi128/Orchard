import Foundation

/// Error que devuelve el proveedor de YouTube (mensaje ya legible).
struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Llamadas al proveedor de YouTube compartido con escritorio y Android.
/// Los métodos y las formas de los datos son los de providers/youtube/src/runtime.
enum Provider {
    static func call(_ method: String, _ payload: [String: Any] = [:]) async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            OrchardEngine.shared().invoke(method, payload: json) { ok, result in
                guard ok else {
                    continuation.resume(throwing: ProviderError(message: result.isEmpty ? "YouTube no respondió." : result))
                    return
                }
                do {
                    let value = try JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: ProviderError(message: "Respuesta inesperada de YouTube."))
                }
            }
        }
    }

    static func object(_ method: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await call(method, payload)
        guard let dictionary = value as? [String: Any] else {
            throw ProviderError(message: "Respuesta inesperada de YouTube.")
        }
        return dictionary
    }

    static func array(_ method: String, _ payload: [String: Any] = [:]) async throws -> [Any] {
        let value = try await call(method, payload)
        if let list = value as? [Any] { return list }
        if let dictionary = value as? [String: Any] {
            for key in ["tracks", "items"] {
                if let list = dictionary[key] as? [Any] { return list }
            }
        }
        return []
    }
}

// MARK: - Catálogo

struct Shelf: Identifiable {
    let id: String
    let title: String
    let items: [CatalogItem]
}

@MainActor
enum Catalog {
    static func session() -> [String: Any] { SessionStore.shared.session?.providerJSON ?? [:] }

    static func search(_ query: String) async throws -> [CatalogItem] {
        var payload: [String: Any] = ["session": session(), "query": query, "filter": "songs"]
        if SessionStore.shared.session == nil { payload["guest"] = true }
        let result = try await Provider.object("catalog.search", payload)
        return items(in: result)
    }

    static func home() async throws -> [Shelf] {
        let result = try await Provider.object("catalog.home", ["session": session()])
        let sections = result["sections"] as? [[String: Any]] ?? []
        return sections.enumerated().compactMap { index, section in
            let items = (section["items"] as? [[String: Any]] ?? []).compactMap(CatalogItem.init(json:))
            guard !items.isEmpty else { return nil }
            let title = (section["title"] as? String) ?? ""
            return Shelf(id: (section["key"] as? String) ?? "shelf-\(index)", title: title, items: items)
        }
    }

    static func playlists() async throws -> [CatalogItem] {
        try await Provider.array("catalog.playlists", ["session": session()])
            .compactMap { ($0 as? [String: Any]).flatMap(CatalogItem.init(json:)) }
    }

    /// Detalle de una playlist o álbum: título y canciones.
    static func collection(_ item: CatalogItem) async throws -> (title: String, tracks: [Track]) {
        guard let browseId = item.browseId else { return (item.title, []) }
        let method = item.kind == .album ? "catalog.album" : "catalog.playlist"
        var payload: [String: Any] = ["session": session(), "browseId": browseId]
        if let extra = item.browsePayload { payload.merge(extra) { current, _ in current } }
        let result = try await Provider.object(method, payload)
        let title = (result["title"] as? String) ?? item.title
        let tracks = (result["tracks"] as? [[String: Any]] ?? result["items"] as? [[String: Any]] ?? [])
            .compactMap(Track.init(json:))
        return (title, tracks)
    }

    /// Canciones parecidas para seguir escuchando (la "radio" de YouTube Music).
    static func upNext(after track: Track) async throws -> [Track] {
        try await Provider.array("catalog.upNext", ["session": session(), "videoId": track.id])
            .compactMap { ($0 as? [String: Any]).flatMap(Track.init(json:)) }
            .filter { $0.id != track.id }
    }

    private static func items(in result: [String: Any]) -> [CatalogItem] {
        var found: [CatalogItem] = []
        var seen = Set<String>()
        func add(_ list: [[String: Any]]) {
            for json in list {
                guard let item = CatalogItem(json: json), seen.insert(item.id).inserted else { continue }
                found.append(item)
            }
        }
        for key in ["tracks", "items", "songs"] {
            if let list = result[key] as? [[String: Any]] { add(list) }
        }
        for section in result["sections"] as? [[String: Any]] ?? [] {
            add(section["items"] as? [[String: Any]] ?? [])
        }
        return found
    }
}
