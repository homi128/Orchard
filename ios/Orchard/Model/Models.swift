import Foundation

/// Una canción o video que se puede reproducir.
struct Track: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Double
    var thumbnail: URL?
    var type: String
    var musicVideoType: String
    var explicit: Bool
    var isUpload: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String ?? json["videoId"] as? String, !id.isEmpty else { return nil }
        let type = (json["type"] as? String) ?? "song"
        guard ["song", "track", "video"].contains(type), json["browseId"] as? String == nil || id.count == 11 else { return nil }
        self.id = id
        self.type = type
        self.title = Self.text(json["title"]) ?? "Sin título"
        if let artists = json["artists"] as? [Any] {
            let names = artists.compactMap { Self.text($0) }.filter { !$0.isEmpty }
            self.artist = names.isEmpty ? (Self.text(json["artist"]) ?? Self.text(json["subtitle"]) ?? "") : names.joined(separator: ", ")
        } else {
            self.artist = Self.text(json["artist"]) ?? Self.text(json["subtitle"]) ?? ""
        }
        self.album = Self.text(json["album"]) ?? ""
        if let seconds = json["durationSeconds"] as? Double, seconds > 0 {
            self.durationSeconds = seconds
        } else if let seconds = json["durationSeconds"] as? Int, seconds > 0 {
            self.durationSeconds = Double(seconds)
        } else {
            self.durationSeconds = Self.clock(json["duration"])
        }
        self.thumbnail = Self.image(json)
        self.musicVideoType = (json["musicVideoType"] as? String) ?? ""
        self.explicit = (json["explicit"] as? Bool) ?? false
        self.isUpload = (json["isUpload"] as? Bool) ?? false
    }

    /// Lo que `playback.*` necesita saber (igual que Track.providerJson() en Android).
    var providerJSON: [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "type": type == "video" || isUpload ? "video" : "track",
            "title": title,
            "artist": artist,
            "album": album,
            "musicVideoType": musicVideoType,
            "explicit": explicit,
            "isUpload": isUpload,
        ]
        if durationSeconds > 0 { json["durationSeconds"] = durationSeconds }
        return json
    }

    /// Lo que se le pide reproducir al proveedor.
    ///
    /// El proveedor, si no sabe que algo ya es la pista de audio, busca primero la "versión de
    /// audio" de la canción (una búsqueda extra en YouTube) y, si es un video, se niega a
    /// reproducirlo cuando la duración no calza exacto con la del catálogo. Aquí la persona ya
    /// eligió qué quiere oír, así que `asIs` pide exactamente eso, sin búsqueda ni control.
    func playbackJSON(asIs: Bool) -> [String: Any] {
        var json = providerJSON
        guard asIs, !isUpload else { return json }
        json["type"] = "track"
        json["musicVideoType"] = "MUSIC_VIDEO_TYPE_ATV"
        return json
    }

    /// Canción publicada como video musical: vale la pena buscar su versión de estudio.
    var isMusicVideoOfSong: Bool {
        type != "video" && ["MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC"].contains(musicVideoType)
    }

    /// Carátula más grande para la pantalla del reproductor.
    var largeThumbnail: URL? {
        guard let url = thumbnail else { return fallbackThumbnail }
        let text = url.absoluteString
        if text.contains("googleusercontent.com"), let range = text.range(of: "=w", options: .backwards) {
            return URL(string: String(text[..<range.lowerBound]) + "=w800-h800-l90-rj") ?? url
        }
        return url
    }

    var fallbackThumbnail: URL? {
        id.count == 11 ? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") : nil
    }

    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let dictionary = value as? [String: Any] {
            return (dictionary["name"] as? String) ?? (dictionary["title"] as? String) ?? (dictionary["text"] as? String)
        }
        return nil
    }

    static func image(_ json: [String: Any]) -> URL? {
        var candidate: String?
        for key in ["thumbnail", "artwork", "thumbnailUrl", "image", "cover"] {
            if let string = json[key] as? String, !string.isEmpty { candidate = string; break }
            if let dictionary = json[key] as? [String: Any], let string = dictionary["url"] as? String { candidate = string; break }
        }
        if candidate == nil, let list = json["thumbnails"] as? [Any], let last = list.last {
            candidate = (last as? String) ?? ((last as? [String: Any])?["url"] as? String)
        }
        guard var text = candidate else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        guard text.hasPrefix("https://") else { return nil }
        return URL(string: text)
    }

    static func clock(_ value: Any?) -> Double {
        guard let text = value as? String, text.contains(":") else { return 0 }
        var total = 0.0
        for part in text.split(separator: ":") {
            guard let number = Double(part) else { return 0 }
            total = total * 60 + number
        }
        return total
    }
}

/// Cualquier fila del catálogo: canción, álbum, playlist o artista.
struct CatalogItem: Identifiable, Hashable {
    enum Kind: String { case track, album, playlist, artist, other }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let thumbnail: URL?
    let browseId: String?
    let track: Track?
    let browsePayloadJSON: String?

    var browsePayload: [String: Any]? {
        guard let json = browsePayloadJSON, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    init?(json: [String: Any]) {
        let type = ((json["type"] as? String) ?? "").lowercased()
        let browseId = (json["browseId"] as? String)
            ?? ((json["browsePayload"] as? [String: Any])?["browseId"] as? String)
        let rawTitle = Track.text(json["title"]) ?? ""
        let isPlayableType = ["song", "track", "video"].contains(type)

        var kind: Kind
        var playable: Track? = nil
        if let browseId, !browseId.isEmpty, !isPlayableType || (json["id"] as? String) == nil {
            if type.contains("album") || type == "single" || type == "ep" {
                kind = .album
            } else if type.contains("artist") {
                kind = .artist
            } else if type.contains("playlist") || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
                kind = .playlist
            } else {
                kind = .other
            }
        } else if let track = Track(json: json) {
            kind = .track
            playable = track
        } else {
            return nil
        }

        self.kind = kind
        self.track = playable
        self.browseId = kind == .track ? nil : browseId
        self.id = kind == .track ? "t:" + (playable?.id ?? "") : "b:" + (browseId ?? "")
        self.title = rawTitle.isEmpty ? (playable?.title ?? "Sin título") : rawTitle
        let artists = (json["artists"] as? [Any])?.compactMap { Track.text($0) }.joined(separator: ", ")
        self.subtitle = Track.text(json["subtitle"]) ?? artists ?? Track.text(json["itemCount"]) ?? ""
        self.thumbnail = Track.image(json) ?? playable?.fallbackThumbnail
        if let payload = json["browsePayload"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: payload) {
            self.browsePayloadJSON = String(decoding: data, as: UTF8.self)
        } else {
            self.browsePayloadJSON = nil
        }
    }

    static func == (lhs: CatalogItem, rhs: CatalogItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
