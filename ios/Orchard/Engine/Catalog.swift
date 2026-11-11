import Foundation

struct Shelf: Identifiable {
    let id: String
    let title: String
    let items: [CatalogItem]
}

/// Resultados de búsqueda agrupados como en Android (ProviderModels.providerSearch).
struct SearchResults {
    var top: [CatalogItem] = []
    var songs: [Track] = []
    var videos: [Track] = []
    var albums: [CatalogItem] = []
    var artists: [CatalogItem] = []
    var playlists: [CatalogItem] = []

    var isEmpty: Bool {
        top.isEmpty && songs.isEmpty && videos.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty
    }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, songs, videos, albums, artists, playlists
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Todo"
        case .songs: return "Canciones"
        case .videos: return "Videos"
        case .albums: return "Álbumes"
        case .artists: return "Artistas"
        case .playlists: return "Playlists"
        }
    }
}

/// Página de playlist, álbum o artista.
struct CollectionPage {
    var title: String
    var subtitle: String
    var thumbnail: URL?
    var tracks: [Track]
    var sections: [Shelf]
    var continuation: String?
    var playlistId: String?
    var editable: Bool
}

struct PlaylistTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let containsTrack: Bool
}

/// Datos que YouTube usa para registrar lo escuchado en tu historial.
struct PlaybackTracking {
    let playbackUrl: String
    let watchtimeUrl: String
    let itag: Int
}

@MainActor
enum Catalog {
    static let likedMusicId = "VLLM"

    static func session() -> [String: Any] { SessionStore.shared.session?.providerJSON ?? [:] }
    private static func payload(_ extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = ["session": session()]
        json.merge(extra) { _, new in new }
        return json
    }

    // MARK: Búsqueda

    /// `quiet` busca como invitado: lo que escribes letra por letra no queda en tu historial de YouTube.
    static func search(_ query: String, filter: SearchFilter, quiet: Bool = false) async throws -> SearchResults {
        var request = payload(["query": query, "filter": filter.rawValue])
        var result: [String: Any] = [:]
        if quiet || SessionStore.shared.session == nil {
            request["guest"] = true
            do {
                result = try await Provider.object("catalog.search", request)
            } catch {
                guard SessionStore.shared.session != nil else { throw error }
                request["guest"] = nil
                result = try await Provider.object("catalog.search", request)
            }
        } else {
            result = try await Provider.object("catalog.search", request)
        }
        var results = SearchResults()
        for section in result["sections"] as? [[String: Any]] ?? [] {
            let key = (section["key"] as? String ?? "").lowercased()
            let items = (section["items"] as? [[String: Any]] ?? []).compactMap(CatalogItem.init(json:))
            switch key {
            case "songs": results.songs += items.compactMap(\.track)
            case "videos": results.videos += items.compactMap(\.track)
            case "albums": results.albums += items.filter { $0.kind != .track }
            case "artists": results.artists += items.filter { $0.kind == .artist }
            case "playlists": results.playlists += items.filter { $0.kind != .track }
            default: results.top += items
            }
        }
        return results
    }

    /// Sugerencias mientras escribes (las mismas que muestra YouTube).
    static func suggestions(_ query: String) async -> [String] {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "hl", value: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "es"),
            URLQueryItem(name: "q", value: query),
        ]
        guard let url = components.url,
              let response = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [Any],
              json.count > 1, let list = json[1] as? [String]
        else { return [] }
        return Array(list.prefix(8))
    }

    // MARK: Inicio y biblioteca

    static func home() async throws -> [Shelf] {
        let result = try await Provider.object("catalog.home", payload())
        return shelves(result["sections"])
    }

    static func playlists() async throws -> [CatalogItem] {
        try await Provider.array("catalog.playlists", payload())
            .compactMap { ($0 as? [String: Any]).flatMap(CatalogItem.init(json:)) }
    }

    /// Artistas, álbumes, canciones y playlists guardados.
    static func library() async throws -> [String: [CatalogItem]] {
        let result = try await Provider.object("catalog.library", payload())
        var sections: [String: [CatalogItem]] = [:]
        for section in result["sections"] as? [[String: Any]] ?? [] {
            let key = section["key"] as? String ?? ""
            sections[key] = (section["items"] as? [[String: Any]] ?? []).compactMap(CatalogItem.init(json:))
        }
        return sections
    }

    // MARK: Páginas

    static func collection(_ item: CatalogItem) async throws -> CollectionPage {
        guard let browseId = item.browseId else {
            return CollectionPage(title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail,
                                  tracks: [], sections: [], continuation: nil, playlistId: nil, editable: false)
        }
        let method: String
        switch item.kind {
        case .album: method = "catalog.album"
        case .artist: method = "catalog.artist"
        default: method = browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") || browseId.hasPrefix("OLAK")
            ? "catalog.playlist" : "catalog.browse"
        }
        var request = payload(["browseId": browseId])
        if let extra = item.browsePayload { request.merge(extra) { current, _ in current } }
        let result = try await Provider.object(method, request)
        return page(result, fallback: item, isAlbum: item.kind == .album)
    }

    static func likedSongs() async throws -> CollectionPage {
        let result = try await Provider.object("catalog.playlist", payload(["browseId": likedMusicId]))
        var page = page(result, fallback: nil, isAlbum: false)
        if page.title.isEmpty { page.title = "Canciones que te gustan" }
        return page
    }

    /// Siguiente tramo de una playlist larga.
    static func more(_ continuation: String, startIndex: Int) async throws -> (tracks: [Track], continuation: String?) {
        let result = try await Provider.object("catalog.playlist.more",
                                               payload(["continuation": continuation, "startIndex": startIndex]))
        let tracks = (result["tracks"] as? [[String: Any]] ?? []).compactMap(Track.init(json:))
        let next = (result["continuation"] as? String).flatMap { $0.isEmpty || $0 == continuation ? nil : $0 }
        return (tracks, next)
    }

    static func upNext(after track: Track) async throws -> [Track] {
        try await Provider.array("catalog.upNext", payload(["videoId": track.id]))
            .compactMap { ($0 as? [String: Any]).flatMap(Track.init(json:)) }
            .filter { $0.id != track.id }
    }

    // MARK: Me gusta y playlists

    static func isLiked(_ track: Track) async -> Bool {
        guard SessionStore.shared.isSignedIn,
              let result = try? await Provider.object("library.like.status", payload(["track": track.providerJSON]))
        else { return false }
        return result["liked"] as? Bool ?? false
    }

    static func setLiked(_ track: Track, _ liked: Bool) async throws {
        _ = try await Provider.call("library.like.set", payload(["track": track.providerJSON, "liked": liked]))
    }

    static func playlistTargets(for track: Track) async throws -> [PlaylistTarget] {
        let result = try await Provider.object("library.playlist.targets", payload(["track": track.providerJSON]))
        return (result["playlists"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return PlaylistTarget(id: id, title: item["title"] as? String ?? "Playlist",
                                  containsTrack: item["containsTrack"] as? Bool ?? false)
        }
    }

    static func add(_ track: Track, toPlaylist playlistId: String) async throws {
        if playlistId == "LM" || playlistId == likedMusicId { return try await setLiked(track, true) }
        _ = try await Provider.call("library.playlist.add",
                                    payload(["track": track.providerJSON, "playlistId": playlistId]))
    }

    static func createPlaylist(_ title: String, with track: Track?) async throws {
        var request = payload(["title": title.trimmingCharacters(in: .whitespacesAndNewlines)])
        if let track { request["track"] = track.providerJSON }
        _ = try await Provider.call("library.playlist.create", request)
    }

    static func removeFromPlaylist(_ playlistId: String, track: Track) async throws {
        if playlistId == "LM" || playlistId == likedMusicId { return try await setLiked(track, false) }
        _ = try await Provider.call("library.playlist.remove",
                                    payload(["playlistId": playlistId, "track": ["id": track.id]]))
    }

    static func setSaved(_ playlistId: String, saved: Bool) async throws {
        _ = try await Provider.call("library.collection.save", payload(["playlistId": playlistId, "saved": saved]))
    }

    // MARK: Historial de YouTube

    static func history(_ method: String, tracking: PlaybackTracking, cpn: String, watchTime: Double, final: Bool) async {
        let request = payload([
            "tracking": ["playbackUrl": tracking.playbackUrl, "watchtimeUrl": tracking.watchtimeUrl, "itag": tracking.itag],
            "cpn": cpn,
            "watchTime": watchTime,
            "final": final,
        ])
        _ = try? await Provider.call(method, request)
    }

    // MARK: Letras

    static func youtubeLyrics(_ videoId: String) async -> String {
        guard let result = try? await Provider.call("lyrics.youtube", payload(["videoId": videoId])) else { return "" }
        if let text = result as? String { return text }
        if let json = result as? [String: Any] {
            return (json["lyrics"] as? String) ?? (json["text"] as? String) ?? ""
        }
        return ""
    }

    // MARK: Conversión

    static func shelves(_ value: Any?) -> [Shelf] {
        let sections = value as? [[String: Any]] ?? []
        return sections.enumerated().compactMap { index, section in
            let items = (section["items"] as? [[String: Any]] ?? []).compactMap(CatalogItem.init(json:))
            guard !items.isEmpty else { return nil }
            let title = (section["title"] as? String) ?? ""
            return Shelf(id: (section["key"] as? String).map { "\($0)-\(index)" } ?? "shelf-\(index)",
                         title: title, items: items)
        }
    }

    private static func page(_ result: [String: Any], fallback: CatalogItem?, isAlbum: Bool) -> CollectionPage {
        let title = (result["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback?.title ?? ""
        let artwork = Track.image(result) ?? fallback?.thumbnail
        var tracks = (result["tracks"] as? [[String: Any]] ?? result["items"] as? [[String: Any]] ?? [])
            .compactMap(Track.init(json:))
        if isAlbum {
            // En un álbum, la carátula del álbum es mejor que la miniatura de video de cada canción.
            tracks = tracks.map { track in
                var copy = track
                if copy.album.isEmpty { copy.album = title }
                if copy.thumbnail == nil || copy.thumbnail?.host == "i.ytimg.com" { copy.thumbnail = artwork }
                return copy
            }
        } else {
            tracks = tracks.map { track in
                var copy = track
                if copy.thumbnail == nil { copy.thumbnail = artwork }
                return copy
            }
        }
        let subtitle = [result["subtitle"], result["artist"], result["year"]]
            .compactMap { Track.text($0) }
            .filter { !$0.isEmpty }
            .first ?? fallback?.subtitle ?? ""
        let continuation = (result["continuation"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let playlistId = (result["audioPlaylistId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (result["playlistId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CollectionPage(title: title, subtitle: subtitle, thumbnail: artwork, tracks: tracks,
                              sections: shelves(result["sections"]), continuation: continuation,
                              playlistId: playlistId, editable: result["editable"] as? Bool ?? false)
    }
}
