import AVFoundation
import ObjectiveC

/// Entrega el audio de YouTube a AVPlayer por tramos acotados.
///
/// YouTube frena al mínimo cualquier pedido sin un final definido ("desde aquí hasta el
/// final"), que es justo lo que AVPlayer pide por su cuenta. Con canciones cortas alcanza,
/// pero un video de una hora no termina nunca de cargar. Android y escritorio piden tramos
/// con principio y fin (PlayerStreams.bounded); este cargador hace lo mismo para iOS.
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let scheme = "orchard-stream"
    private static var associationKey: UInt8 = 0
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private let url: URL
    private let headers: [String: String]
    private let contentLength: Int64
    /// Bytes por segundo de audio, para no descargar una hora entera de golpe.
    private let bytesPerSecond: Double
    private let queue = DispatchQueue(label: "orchard.stream.loader")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private static let firstChunk: Int64 = 256 * 1024
    private static let chunk: Int64 = 1024 * 1024
    /// Lo que se baja sin pausas antes de empezar a dosificar.
    private static let burst: Int64 = 4 * 1024 * 1024

    private init(stream: ResolvedStream) {
        url = stream.url
        headers = stream.headers
        contentLength = stream.contentLength
        bytesPerSecond = stream.duration > 0 ? Double(stream.contentLength) / stream.duration : 0
    }

    /// Un asset que lee a través de este cargador, o nil si falta el tamaño del archivo.
    static func asset(for stream: ResolvedStream, id: String) -> AVURLAsset? {
        guard stream.contentLength > 0,
              let fake = URL(string: "\(scheme)://audio/\(id).m4a") else { return nil }
        let loader = StreamLoader(stream: stream)
        let asset = AVURLAsset(url: fake)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // AVFoundation no retiene al delegado: atarlo a la vida del asset.
        objc_setAssociatedObject(asset, &associationKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
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

    private func serve(_ request: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64) async {
        guard let dataRequest = request.dataRequest else { return }
        var offset = start
        var served: Int64 = 0
        while offset < end {
            if Task.isCancelled || request.isCancelled { return }
            let size = served == 0 ? Self.firstChunk : Self.chunk
            let last = min(offset + size, end) - 1
            var fetch = URLRequest(url: url)
            for (name, value) in headers { fetch.setValue(value, forHTTPHeaderField: name) }
            fetch.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await Self.session.data(for: fetch)
                if Task.isCancelled || request.isCancelled { return }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                // 206 = el tramo pedido. Un 200 solo sirve si se pidió desde el principio.
                guard http.statusCode == 206 || (http.statusCode == 200 && offset == 0), !data.isEmpty else {
                    throw NSError(domain: "OrchardStream", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "YouTube rechazó el audio (\(http.statusCode))."])
                }
                let usable = data.prefix(Int(end - offset))
                dataRequest.respond(with: Data(usable))
                offset += Int64(usable.count)
                served += Int64(usable.count)
            } catch {
                if Task.isCancelled || request.isCancelled { return }
                request.finishLoading(with: error)
                return
            }
            // Pasada la ráfaga inicial, bajar a unas 4 veces la velocidad de reproducción:
            // sobra para no cortarse y no llena la memoria con una hora de audio.
            if served > Self.burst, bytesPerSecond > 0, offset < end {
                let seconds = Double(Self.chunk) / (bytesPerSecond * 4)
                try? await Task.sleep(nanoseconds: UInt64(min(seconds, 20) * 1_000_000_000))
            }
        }
        if !request.isCancelled { request.finishLoading() }
    }
}
