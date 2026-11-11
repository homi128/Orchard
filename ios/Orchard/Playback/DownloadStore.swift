import Foundation
import Network

/// Canciones guardadas en el iPhone para escuchar sin conexión.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    struct Entry: Codable, Identifiable, Hashable {
        let track: Track
        let file: String
        let bytes: Int64
        let date: Date
        var id: String { track.id }
    }

    @Published private(set) var entries: [Entry] = []
    /// Progreso de las descargas en curso (0...1), por id de canción.
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    private var tasks: [String: Task<Void, Never>] = [:]
    private let monitor = NWPathMonitor()
    private var onCellular = false

    private var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Descargas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var indexURL: URL { folder.appendingPathComponent("descargas.json") }

    private init() {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.onCellular = cellular }
        }
        monitor.start(queue: DispatchQueue(label: "orchard.downloads.network"))
    }

    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    func isDownloaded(_ id: String) -> Bool { entries.contains { $0.id == id } }

    func fileURL(for id: String) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        let url = folder.appendingPathComponent(entry.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ tracks: [Track]) {
        for track in tracks where !isDownloaded(track.id) && tasks[track.id] == nil {
            download(track)
        }
    }

    func download(_ track: Track) {
        guard !isDownloaded(track.id), tasks[track.id] == nil else { return }
        if onCellular && !AppSettings.shared.downloadOnCellular {
            lastError = "Las descargas con datos móviles están desactivadas en Ajustes."
            return
        }
        progress[track.id] = 0
        tasks[track.id] = Task { [weak self] in
            await self?.run(track)
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
    }

    func delete(_ id: String) {
        cancel(id)
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))
        entries.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        for entry in entries { try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file)) }
        entries = []
        save()
    }

    private func run(_ track: Track) async {
        defer {
            tasks[track.id] = nil
            progress[track.id] = nil
        }
        do {
            let stream = try await Player.shared.resolve(track)
            var request = URLRequest(url: stream.url)
            for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
            let file = "\(track.id).m4a"
            let destination = folder.appendingPathComponent(file)
            let bytes = try await fetch(request, to: destination, id: track.id)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            var saved = track
            saved.thumbnail = track.largeThumbnail ?? track.thumbnail
            entries.removeAll { $0.id == track.id }
            entries.insert(Entry(track: saved, file: file, bytes: bytes, date: Date()), at: 0)
            save()
        } catch {
            if !Task.isCancelled { lastError = "No se pudo descargar \(track.title): \(error.localizedDescription)" }
        }
    }

    /// Descarga por tramos de 1 MB: YouTube frena las descargas de un solo pedido.
    private func fetch(_ base: URLRequest, to destination: URL, id: String) async throws -> Int64 {
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let chunk: Int64 = 1_048_576
        var offset: Int64 = 0
        var total: Int64?
        while total == nil || offset < total! {
            try Task.checkCancellation()
            var request = base
            request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw ProviderError(message: "YouTube rechazó la descarga.")
            }
            if total == nil {
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let size = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                    total = size
                } else {
                    // El servidor mandó el archivo completo de una vez.
                    total = Int64(data.count)
                }
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if data.isEmpty { break }
            progress[id] = Double(offset) / Double(max(total ?? 1, 1))
        }
        try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return offset
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }
}
