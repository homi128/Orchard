import AVFoundation
import ObjectiveC

/// Entrega el audio de YouTube a AVPlayer con pedidos acotados.
///
/// YouTube frena al mínimo cualquier pedido sin final definido ("desde aquí hasta el
/// final"), que es lo que AVPlayer pide por su cuenta. Android y escritorio piden el rango
/// completo con principio y fin (PlayerStreams.bounded) y lo reciben de inmediato; este
/// cargador hace lo mismo: por cada lectura de AVPlayer, un solo pedido "bytes=a-b" que se
/// va entregando a medida que llega.
///
/// Si un pedido se corta, sigue una escalera: reintentar, renovar el enlace (nuevo token) y,
/// como último recurso, pedir sin final definido, que es lento pero es lo que usaba antes.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "orchard-stream"
    private static var associationKey: UInt8 = 0

    private let lock = NSLock()
    private var url: URL
    private var headers: [String: String]
    private let contentLength: Int64
    /// Bytes por segundo de audio, para dosificar las canciones largas.
    private let bytesPerSecond: Double
    private let queue = DispatchQueue(label: "orchard.stream.loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var head: Task<Data?, Never>!
    /// Pide un enlace nuevo al proveedor (con token renovado).
    private let refresh: () async -> ResolvedStream?
    /// Avisa de cada tropiezo; el último argumento indica si ya no hay nada más que intentar.
    private let report: (String, Bool) -> Void
    private var refreshed = false

    private static let headBytes: Int64 = 256 * 1024
    /// Lo que se baja sin pausas antes de empezar a dosificar.
    private static let burst: Int64 = 8 * 1024 * 1024

    private init(stream: ResolvedStream, refresh: @escaping () async -> ResolvedStream?,
                 report: @escaping (String, Bool) -> Void) {
        url = stream.url
        headers = stream.headers
        contentLength = stream.contentLength
        bytesPerSecond = stream.duration > 0 ? Double(stream.contentLength) / stream.duration : 0
        self.refresh = refresh
        self.report = report
        super.init()
        let length = min(Self.headBytes, contentLength)
        let request = makeRequest(from: 0, to: length, openEnded: false)
        head = Task {
            var data = Data()
            do {
                for try await piece in StreamHTTP.shared.stream(request).pieces { data.append(piece) }
            } catch {
                return data.isEmpty ? nil : data
            }
            return data.isEmpty ? nil : Data(data.prefix(Int(length)))
        }
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

    private func makeRequest(from offset: Int64, to end: Int64, openEnded: Bool) -> URLRequest {
        lock.lock()
        let currentURL = url
        let currentHeaders = headers
        lock.unlock()
        var request = URLRequest(url: currentURL)
        for (name, value) in currentHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(openEnded ? "bytes=\(offset)-" : "bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

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

    private func serve(_ request: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64) async {
        guard let dataRequest = request.dataRequest else { return }
        var offset = start

        // Lo que caiga dentro del comienzo ya descargado se entrega desde memoria.
        if offset < Self.headBytes, let data = await head.value, offset < Int64(data.count) {
            if Task.isCancelled || request.isCancelled { return }
            let upper = min(end, Int64(data.count))
            dataRequest.respond(with: data.subdata(in: Int(offset)..<Int(upper)))
            offset = upper
        }

        let began = Date()
        var delivered: Int64 = 0
        var failures = 0
        var openEnded = false
        while offset < end {
            if Task.isCancelled || request.isCancelled { return }
            let connection = StreamHTTP.shared.stream(makeRequest(from: offset, to: end, openEnded: openEnded))
            do {
                for try await piece in connection.pieces {
                    if Task.isCancelled || request.isCancelled {
                        connection.cancel()
                        return
                    }
                    let usable = piece.prefix(Int(end - offset))
                    guard !usable.isEmpty else { continue }
                    dataRequest.respond(with: Data(usable))
                    offset += Int64(usable.count)
                    delivered += Int64(usable.count)
                    if offset >= end {
                        connection.cancel()
                        break
                    }
                    // Canciones largas: pasada la ráfaga inicial, no bajar más de unas 4 veces
                    // la velocidad de reproducción, para no llenar la memoria con una hora de audio.
                    if delivered > Self.burst, bytesPerSecond > 0 {
                        let allowed = Double(Self.burst) + Date().timeIntervalSince(began) * bytesPerSecond * 4
                        if Double(delivered) > allowed {
                            connection.suspend()
                            let wait = min((Double(delivered) - allowed) / (bytesPerSecond * 4), 15)
                            try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.2) * 1_000_000_000))
                            connection.resume()
                        }
                    }
                }
                if offset < end {
                    // El servidor cerró antes de entregar todo: tratarlo como un corte.
                    throw StreamHTTP.Failure.truncated
                }
            } catch {
                if Task.isCancelled || request.isCancelled { return }
                failures += 1
                let reason = (error as? StreamHTTP.Failure)?.text ?? error.localizedDescription
                let place = megabytes(offset)
                switch failures {
                case 1:
                    report("corte en \(place): \(reason), reintentando", false)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                case 2:
                    report("corte en \(place): \(reason), renovando el enlace", false)
                    if let fresh = await refresh() {
                        lock.lock()
                        url = fresh.url
                        headers = fresh.headers
                        refreshed = true
                        lock.unlock()
                    }
                case 3:
                    report("corte en \(place): \(reason), probando sin rango acotado", false)
                    openEnded = true
                default:
                    report("YouTube dejó de entregar el audio en \(place): \(reason)", true)
                    request.finishLoading(with: error)
                    return
                }
            }
        }
        if !request.isCancelled { request.finishLoading() }
    }
}

/// Pedidos HTTP cuyos datos se entregan a medida que llegan.
final class StreamHTTP: NSObject, URLSessionDataDelegate {
    static let shared = StreamHTTP()

    enum Failure: Error {
        case status(Int)
        case truncated
        var text: String {
            switch self {
            case .status(let code): return "HTTP \(code)"
            case .truncated: return "conexión cerrada"
            }
        }
    }

    struct Connection {
        let pieces: AsyncThrowingStream<Data, Error>
        fileprivate let task: URLSessionDataTask
        func cancel() { task.cancel() }
        func suspend() { task.suspend() }
        func resume() { task.resume() }
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var continuations: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 25
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func stream(_ request: URLRequest) -> Connection {
        let task = session.dataTask(with: request)
        let identifier = task.taskIdentifier
        let pieces = AsyncThrowingStream<Data, Error> { continuation in
            self.lock.lock()
            self.continuations[identifier] = continuation
            self.lock.unlock()
            continuation.onTermination = { _ in task.cancel() }
        }
        task.resume()
        return Connection(pieces: pieces, task: task)
    }

    private func take(_ identifier: Int) -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations.removeValue(forKey: identifier)
    }

    private func peek(_ identifier: Int) -> AsyncThrowingStream<Data, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations[identifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 206 = el rango pedido. Un 200 significaría el archivo entero desde cero, que no sirve
        // para un pedido que empieza más adelante.
        let startsAtZero = dataTask.originalRequest?.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=0-") ?? false
        if status == 206 || (status == 200 && startsAtZero) {
            completionHandler(.allow)
        } else {
            take(dataTask.taskIdentifier)?.finish(throwing: Failure.status(status))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        peek(dataTask.taskIdentifier)?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = take(task.taskIdentifier) else { return }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
