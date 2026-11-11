import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    /// Segundo en que empieza la línea; nil si la letra no está sincronizada.
    let time: Double?
    let text: String
}

struct LyricsResult {
    let lines: [LyricLine]
    let synced: Bool
    let source: String
}

/// Letras: primero LRCLIB (sincronizadas), si no, la pestaña de letras de YouTube Music.
enum Lyrics {
    private static var cache: [String: LyricsResult] = [:]

    @MainActor
    static func load(for track: Track) async -> LyricsResult? {
        if let cached = cache[track.id] { return cached }
        let result: LyricsResult?
        if let lrc = await lrclib(track) {
            result = lrc
        } else {
            let text = await Catalog.youtubeLyrics(track.id)
            result = text.isEmpty ? nil : plain(text, source: "YouTube Music")
        }
        if let result { cache[track.id] = result }
        return result
    }

    private static func lrclib(_ track: Track) async -> LyricsResult? {
        let artist = track.artist.components(separatedBy: ", ").first ?? track.artist
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !track.album.isEmpty { exact.queryItems?.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.durationSeconds > 0 {
            exact.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(track.durationSeconds))))
        }
        if let json = await request(exact.url) as? [String: Any], let result = parse(json) { return result }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let list = await request(search.url) as? [[String: Any]] else { return nil }
        // Preferir una con letra sincronizada y duración parecida.
        let sorted = list.sorted { lhs, rhs in
            let l = (lhs["syncedLyrics"] as? String)?.isEmpty == false
            let r = (rhs["syncedLyrics"] as? String)?.isEmpty == false
            if l != r { return l }
            let dl = abs((lhs["duration"] as? Double ?? 0) - track.durationSeconds)
            let dr = abs((rhs["duration"] as? Double ?? 0) - track.durationSeconds)
            return dl < dr
        }
        for json in sorted { if let result = parse(json) { return result } }
        return nil
    }

    private static func request(_ url: URL?) async -> Any? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Orchard iOS (https://github.com/SFG5453/Orchard)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let response = try? await URLSession.shared.data(for: request),
              (response.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: response.0)
    }

    private static func parse(_ json: [String: Any]) -> LyricsResult? {
        if json["instrumental"] as? Bool == true {
            return LyricsResult(lines: [LyricLine(id: 0, time: nil, text: "Instrumental")], synced: false, source: "LRCLIB")
        }
        if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return LyricsResult(lines: lines, synced: true, source: "LRCLIB") }
        }
        if let text = json["plainLyrics"] as? String, !text.isEmpty { return plain(text, source: "LRCLIB") }
        return nil
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { lines.append((time, words)) }
        }
        return lines.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    private static func plain(_ text: String, source: String) -> LyricsResult {
        let lines = text.components(separatedBy: .newlines).enumerated()
            .map { LyricLine(id: $0.offset, time: nil, text: $0.element.trimmingCharacters(in: .whitespaces)) }
        return LyricsResult(lines: lines, synced: false, source: source)
    }
}
