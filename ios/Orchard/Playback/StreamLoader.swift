import AVFoundation
import ObjectiveC

/// Entrega el audio de YouTube a AVPlayer en tramos cortos e independientes.
///
/// Una sola conexión larga resultó frágil en el iPhone: YouTube (o la red) la corta a los
/// pocos megabytes y con ella se queda la canción entera en silencio. Aquí el archivo se baja
/// en tramos de 256 KB, como hace la caché de Android (StreamCache.fetchByRanges): cada tramo
/// es un pedido "bytes=a-b" que termina en menos de un segundo, varios van en paralelo por
/// delante de lo que suena, y si uno falla se reintenta solo ese, con una conexión nueva y,
/// si hace falta, con un enlace renovado. Un corte cuesta un reintento, no la canción.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "orchard-stream"
    private static var associationKey: UInt8 = 0

    private static let chunkBytes: Int64 = 256 * 1024
    /// Tramos que se piden por adelantado mientras se entrega el actual.
    private static let readAhead = 4
    /// Cuánto se baja por delante de lo que está sonando.
    private static let window: Int64 = 8 * 1024 * 1024
    /// Lo que un pedido recibe siempre sin esperas, suene donde suene.
    private static let freePass: Int64 = 2 * 1024 * 1024
    /// Tramos en memoria como máximo (24 MB); en videos largos se sueltan los más lejanos.
    private static let maxChunks = 96
    /// Esperas entre reintentos de un mismo tramo. Uno más que esperas: 9 intentos.
    private static let backoff: [Double] = [0.2, 0.5, 1, 1.5, 2, 3, 4, 5]

    private let lock = NSLock()
    private var url: URL
    private var headers: [String: String]
    private let contentLength: Int64
    private let bytesPerSecond: Double
    private let queue = DispatchQueue(label: "orchard.stream.loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var chunks: [Int: Data] = [:]
    private var inflight: [Int: Task<Data, Error>] = [:]
    private var lastServed = 0
    private var playhead: Double = 0
    private var renewedAt: Date?
    /// Pide un enlace nuevo al proveedor (con token renovado).
    private let refresh: () async -> ResolvedStream?
    /// Avisa de cada tropiezo; el último argumento indica si ya no hay nada más que intentar.
    private let report: (String, Bool) -> Void

    private init(stream: ResolvedStream, refresh: @escaping () async -> ResolvedStream?,
                 report: @escaping (String, Bool) -> Void) {
        url = stream.url
        headers = stream.headers
        contentLength = stream.contentLength
        bytesPerSecond = stream.duration > 0 ? Double(stream.contentLength) / stream.duration : 0
        self.refresh = refresh
        self.report = report
        super.init()
        // El comienzo se pide de inmediato, antes de que AVPlayer lo solicite.
        prefetch(from: 0, upTo: contentLength)
    }

    /// Un asset que lee a través de este cargador, o nil si falta el tamaño del archivo.
    static func asset(for stream: ResolvedStream, id: String,
                      refresh: @escaping () async -> ResolvedStream?,
                      report: @escaping (String, Bool) -> Void) -> AVURLAsset? {
        guard stream.contentLength > 0,
              let fake = URL(string: "\(scheme)://audio/\(id).m4a") else { return nil }
        let loader = StreamLoader(stream: stream, refresh: refresh, report: report)
        let asset = AVURLAsset(url: fake)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // AVFoundation no retiene al delegado: atarlo a la vida del asset.
        objc_setAssociatedObject(asset, &associationKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    /// Avisa por dónde va la reproducción (o adónde se adelantó), para bajar lo que viene.
    static func note(playhead seconds: Double, for asset: AVAsset?) {
        guard let asset,
              let loader = objc_getAssociatedObject(asset, &associationKey) as? StreamLoader else { return }
        loader.lock.lock()
        loader.playhead = seconds
        loader.lock.unlock()
    }

    // MARK: - Pedidos de AVPlayer

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = AVFileType.m4a.rawValue
            info.contentLength = contentLength
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let start = data.currentOffset
        let wanted = data.requestsAllDataToEndOfResource
            ? contentLength
            : data.requestedOffset + Int64(data.requestedLength)
        let end = min(wanted, contentLength)
        let key = ObjectIdentifier(request)
        tasks[key] = Task { [weak self] in
            await self?.serve(request, from: start, to: end)
            self?.queue.async { self?.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(request)
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Hasta qué byte conviene tener bajado según lo que está sonando.
    private func allowedLimit() -> Int64 {
        guard bytesPerSecond > 0 else { return .max }
        lock.lock()
        let seconds = playhead
        lock.unlock()
        return Int64(seconds * bytesPerSecond) + Self.window
    }

    private func serve(_ request: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64) async {
        guard let dataRequest = request.dataRequest else { return }
        var offset = start
        var delivered: Int64 = 0
        while offset < end {
            if Task.isCancelled || request.isCancelled { return }
            // Videos largos: no bajar la hora entera de una vez, solo lo que viene.
            if delivered > Self.freePass {
                while offset > allowedLimit() {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled || request.isCancelled { return }
                }
            }
            let index = Int(offset / Self.chunkBytes)
            prefetch(from: index + 1, upTo: min(end, max(allowedLimit(), offset + Self.freePass)))
            do {
                let data = try await chunk(index)
                if Task.isCancelled || request.isCancelled { return }
                let base = Int64(index) * Self.chunkBytes
                let lower = Int(offset - base)
                let upper = Int(min(end, base + Int64(data.count)) - base)
                guard upper > lower else { throw StreamHTTP.Failure.truncated("") }
                dataRequest.respond(with: data.subdata(in: lower..<upper))
                offset += Int64(upper - lower)
                delivered += Int64(upper - lower)
            } catch {
                if Task.isCancelled || request.isCancelled { return }
                let reason = (error as? StreamHTTP.Failure)?.text ?? error.localizedDescription
                report("YouTube dejó de entregar el audio en \(megabytes(offset)): \(reason)", true)
                request.finishLoading(with: error)
                return
            }
        }
        if !request.isCancelled { request.finishLoading() }
    }

    // MARK: - Tramos

    private func prefetch(from first: Int, upTo limit: Int64) {
        guard first >= 0 else { return }
        for index in first..<(first + Self.readAhead) {
            guard Int64(index) * Self.chunkBytes < min(limit, contentLength) else { return }
            _ = task(for: index, serving: false)
        }
    }

    /// La descarga (en curso o nueva) del tramo `index`; nil si ya está en memoria.
    private func task(for index: Int, serving: Bool) -> Task<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        if serving { lastServed = index }
        if chunks[index] != nil { return nil }
        if let running = inflight[index] { return running }
        let created = Task<Data, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let data = try await self.download(index)
                self.store(data, at: index)
                return data
            } catch {
                self.lock.lock()
                self.inflight[index] = nil
                self.lock.unlock()
                throw error
            }
        }
        inflight[index] = created
        return created
    }

    private func chunk(_ index: Int) async throws -> Data {
        if let running = task(for: index, serving: true) { return try await running.value }
        lock.lock()
        let cached = chunks[index]
        lock.unlock()
        if let cached { return cached }
        // Lo soltaron de la memoria justo ahora: pedirlo de nuevo.
        guard let again = task(for: index, serving: true) else { throw StreamHTTP.Failure.truncated("") }
        return try await again.value
    }

    private func store(_ data: Data, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        chunks[index] = data
        inflight[index] = nil
        guard chunks.count > Self.maxChunks else { return }
        // Soltar los tramos más lejanos de lo que se está leyendo; el primero tiene el índice
        // del archivo y se conserva siempre.
        let center = lastServed
        let farthest = chunks.keys.filter { $0 != 0 && $0 != index }
            .sorted { abs($0 - center) > abs($1 - center) }
        for key in farthest.prefix(chunks.count - Self.maxChunks) { chunks[key] = nil }
    }

    private func makeRequest(from lower: Int64, to upper: Int64) -> URLRequest {
        lock.lock()
        let currentURL = url
        let currentHeaders = headers
        lock.unlock()
        var request = URLRequest(url: currentURL)
        for (name, value) in currentHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(lower)-\(upper - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    /// Baja un tramo, insistiendo: reintento con conexión nueva, enlace renovado y esperas
    /// cada vez más largas antes de rendirse.
    private func download(_ index: Int) async throws -> Data {
        let lower = Int64(index) * Self.chunkBytes
        let upper = min(lower + Self.chunkBytes, contentLength)
        let place = megabytes(lower)
        var lastError: Error = StreamHTTP.Failure.truncated("")
        for attempt in 0...Self.backoff.count {
            do {
                let result = try await StreamHTTP.shared.fetch(makeRequest(from: lower, to: upper),
                                                               fresh: attempt > 0)
                guard Int64(result.data.count) >= upper - lower else {
                    throw StreamHTTP.Failure.truncated(result.transport)
                }
                if attempt > 0 {
                    report("tramo en \(place) recuperado al intento \(attempt + 1) (\(result.transport))", false)
                }
                // Copia propia desde cero: los subdatos conservan índices del original.
                return Data(result.data.prefix(Int(upper - lower)))
            } catch {
                lastError = error
                let reason = (error as? StreamHTTP.Failure)?.text ?? error.localizedDescription
                guard attempt < Self.backoff.count else { break }
                // Al segundo y al quinto tropiezo, pedir un enlace nuevo (con token nuevo).
                let renewing = attempt == 1 || attempt == 4
                report("corte en \(place): \(reason), "
                       + (renewing ? "renovando el enlace" : "reintento \(attempt + 1)"), false)
                if renewing { await renew() }
                try? await Task.sleep(nanoseconds: UInt64(Self.backoff[attempt] * 1_000_000_000))
            }
        }
        throw lastError
    }

    /// Renueva el enlace una sola vez aunque varios tramos lo pidan a la vez.
    private func renew() async {
        lock.lock()
        if let renewedAt, Date().timeIntervalSince(renewedAt) < 20 {
            lock.unlock()
            return
        }
        renewedAt = Date()
        lock.unlock()
        guard let fresh = await refresh() else { return }
        lock.lock()
        url = fresh.url
        headers = fresh.headers
        lock.unlock()
    }
}

/// Pedidos HTTP de un tramo, con el protocolo usado para el diagnóstico.
final class StreamHTTP {
    static let shared = StreamHTTP()

    enum Failure: Error {
        case status(Int, String)
        case truncated(String)
        case network(Int, String, String)
        var text: String {
            switch self {
            case .status(let code, let transport): return "HTTP \(code)" + Self.suffix(transport)
            case .truncated(let transport): return "respuesta incompleta" + Self.suffix(transport)
            case .network(let code, let message, let transport):
                return "\(message) [\(code)]" + Self.suffix(transport)
            }
        }
        private static func suffix(_ transport: String) -> String {
            transport.isEmpty ? "" : " (\(transport))"
        }
    }

    /// Anota con qué protocolo viajó el pedido (h2, h3...).
    private final class Probe: NSObject, URLSessionTaskDelegate {
        var transport = ""
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            transport = metrics.transactionMetrics.last?.networkProtocolName ?? ""
        }
    }

    private let session: URLSession

    private static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 40
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return config
    }

    private init() {
        session = URLSession(configuration: Self.configuration())
    }

    /// `fresh` usa una sesión recién creada: conexión nueva, sin nada heredado de la que falló.
    func fetch(_ request: URLRequest, fresh: Bool) async throws -> (data: Data, transport: String) {
        let probe = Probe()
        let active = fresh ? URLSession(configuration: Self.configuration()) : session
        defer { if fresh { active.finishTasksAndInvalidate() } }
        do {
            let (data, response) = try await active.data(for: request, delegate: probe)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 206 = el rango pedido. Un 200 es el archivo entero desde cero: solo sirve si
            // el tramo pedido también empezaba en cero.
            let startsAtZero = request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=0-") ?? false
            guard status == 206 || (status == 200 && startsAtZero) else {
                throw Failure.status(status, probe.transport)
            }
            return (data, probe.transport)
        } catch let failure as Failure {
            throw failure
        } catch {
            let code = (error as NSError).code
            throw Failure.network(code, error.localizedDescription, probe.transport)
        }
    }
}
