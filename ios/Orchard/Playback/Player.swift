import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Un stream listo para AVPlayer, como ResolvedStream en Android.
struct ResolvedStream {
    let url: URL
    let headers: [String: String]
    let expiresAt: Date
    let tracking: PlaybackTracking?
    /// Duración real según YouTube. AVPlayer a veces informa el doble en estos archivos.
    let duration: Double
    /// Tamaño del archivo en bytes (0 si YouTube no lo informó).
    let contentLength: Int64
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
    var icon: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

/// Reproductor con dos AVPlayer: uno suena y el otro prepara la siguiente canción,
/// para pasar de una a otra sin silencios o con crossfade.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepAtEndOfTrack = false
    @Published private(set) var liked = false

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: [Track] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    private final class Deck {
        let player = AVPlayer()
        var trackId: String?
        var item: AVPlayerItem?
        var observers: [NSKeyValueObservation] = []
        var ready = false
        var failedOnce = false
        /// Carga por tramos (StreamLoader) en vez de dejar que AVPlayer pida el archivo solo.
        var chunked = false
        var startedAt = Date()
        init() {
            player.automaticallyWaitsToMinimizeStalling = true
            player.actionAtItemEnd = .pause
        }
        func clear() {
            observers = []
            player.pause()
            player.replaceCurrentItem(with: nil)
            item = nil
            trackId = nil
            ready = false
            failedOnce = false
            player.volume = 1
        }
    }

    private var active = Deck()
    private var standby = Deck()
    private var streams: [String: ResolvedStream] = [:]
    private var loadTask: Task<Void, Never>?
    private var standbyTask: Task<Void, Never>?
    private var ticker: Timer?
    private var fading = false
    private var fadeStart: Date?
    private var refilling = false
    private var unshuffled: [Track] = []
    private var artwork: (id: String, image: MPMediaItemArtwork)?
    private var endObserver: NSObjectProtocol?
    private let settings = AppSettings.shared

    /// Posición a la que volver tras recargar la canción (al activar el ecualizador).
    private var resumeAt: Double?
    private var resumePaused = false

    /// Canción cuyo final ya se procesó, para no avanzar dos veces.
    private var endedTrackId: String?

    // Historial de YouTube
    private var historyCpn = ""
    private var historyTrackId = ""
    private var historyReported: Double = 0

    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    private static let musicOrigin = "https://music.youtube.com"

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                               queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        restoreQueue()
    }

    // MARK: - Controles

    func play(_ tracks: [Track], startAt start: Int = 0, shuffled: Bool = false) {
        guard tracks.indices.contains(start) else { return }
        finishHistory()
        if shuffled {
            unshuffled = tracks
            var rest = tracks
            let first = rest.remove(at: start)
            queue = [first] + rest.shuffled()
            index = 0
            shuffle = true
        } else {
            queue = tracks
            index = start
            if shuffle { shuffle = false; unshuffled = [] }
        }
        loadCurrent()
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.insert(track, at: min(index + 1, queue.count))
        resetStandby()
        saveQueue()
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { play(tracks); return }
        queue.append(contentsOf: tracks)
        if upcoming.count == tracks.count { resetStandby() }
        saveQueue()
    }

    func addToQueue(_ track: Track) { addToQueue([track]) }

    func toggle() {
        if active.item == nil {
            if current != nil { loadCurrent() }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        active.player.play()
        if fading { standby.player.play() }
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        active.player.pause()
        if fading { finishFade() }
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard current != nil else { return }
        if fading { finishFade(); return }
        if queue.indices.contains(index + 1) {
            advance(using: standby.trackId == queue[index + 1].id && standby.ready)
        } else if repeatMode == .all, !queue.isEmpty {
            finishHistory()
            index = 0
            loadCurrent()
        } else {
            Task { await refill(thenAdvance: true) }
        }
    }

    func previous() {
        if position > 4 || index == 0 {
            seek(to: 0)
            return
        }
        finishHistory()
        index -= 1
        loadCurrent()
    }

    func seek(to seconds: Double) {
        if fading { finishFade() }
        endedTrackId = nil
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        active.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        position = max(0, seconds)
    }

    func jump(toQueueIndex newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        finishHistory()
        index = newIndex
        loadCurrent()
    }

    func toggleShuffle() {
        guard let now = current else { shuffle.toggle(); return }
        if shuffle {
            // Volver al orden original, manteniendo la canción actual.
            let original = unshuffled.isEmpty ? queue : unshuffled
            let added = queue.filter { track in !original.contains(where: { $0.id == track.id }) }
            queue = original + added
            index = queue.firstIndex(where: { $0.id == now.id }) ?? 0
            unshuffled = []
            shuffle = false
        } else {
            unshuffled = queue
            let rest = upcoming.shuffled()
            queue = Array(queue[...index]) + rest
            shuffle = true
        }
        resetStandby()
        saveQueue()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Mueve canciones de "a continuación" (índices relativos a `upcoming`).
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var rest = upcoming
        rest.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + rest
        resetStandby()
        saveQueue()
    }

    func removeUpcoming(at offsets: IndexSet) {
        var rest = upcoming
        rest.remove(atOffsets: offsets)
        queue = Array(queue[...index]) + rest
        resetStandby()
        saveQueue()
    }

    func clearUpcoming() {
        guard !queue.isEmpty else { return }
        queue = Array(queue[...index])
        resetStandby()
        saveQueue()
    }

    /// Recarga la canción actual en el mismo punto. El ecualizador se conecta al cargar
    /// una canción, así que al activarlo hay que volver a cargarla.
    func reloadKeepingPosition() {
        guard current != nil, active.item != nil else { return }
        let target = position
        let paused = !isPlaying
        loadCurrent()
        resumeAt = target
        resumePaused = paused
    }

    // MARK: - Temporizador

    func sleep(after minutes: Int) {
        sleepAtEndOfTrack = false
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func sleepAtEndOfCurrentTrack() {
        sleepAt = nil
        sleepAtEndOfTrack = true
    }

    func cancelSleep() {
        sleepAt = nil
        sleepAtEndOfTrack = false
    }

    // MARK: - Me gusta

    func toggleLike() {
        guard let track = current else { return }
        let newValue = !liked
        liked = newValue
        Task {
            do { try await Catalog.setLiked(track, newValue) } catch {
                if current?.id == track.id { liked = !newValue }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshLike() {
        guard let track = current else { liked = false; return }
        liked = false
        Task {
            let value = await Catalog.isLiked(track)
            if current?.id == track.id { liked = value }
        }
    }

    // MARK: - Carga

    private func loadCurrent() {
        guard let track = current else { return }
        loadTask?.cancel()
        standbyTask?.cancel()
        if fading { fading = false }
        active.clear()
        standby.clear()
        isLoading = true
        errorMessage = nil
        position = 0
        duration = track.durationSeconds
        endedTrackId = nil
        resumeAt = nil
        isPlaying = true
        updateNowPlaying()
        refreshLike()
        saveQueue()
        loadTask = Task { [weak self] in
            await self?.start(track, on: nil, refresh: false)
        }
    }

    /// Carga `track` en un reproductor. `deck == nil` significa el activo, y empieza a sonar.
    private func start(_ track: Track, on deck: Deck?, refresh: Bool, direct: Bool = false) async {
        let target = deck ?? active
        do {
            let loaded = try await asset(for: track, refresh: refresh, direct: direct)
            let asset = loaded.asset
            guard !Task.isCancelled else { return }
            if deck == nil { guard current?.id == track.id else { return } }
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 30
            if settings.eqEnabled {
                await Equalizer.attach(to: item, asset: asset)
                guard !Task.isCancelled else { return }
                if deck == nil { guard current?.id == track.id else { return } }
            }
            target.observers = []
            target.trackId = track.id
            target.item = item
            target.ready = false
            target.chunked = loaded.chunked
            target.startedAt = Date()
            target.player.replaceCurrentItem(with: item)
            observe(target, track: track)
            if deck == nil {
                try? AVAudioSession.sharedInstance().setActive(true)
                target.player.volume = 1
                target.player.play()
                attachEndObserver()
                updateNowPlaying()
            } else {
                target.player.volume = 0
                target.player.pause()
            }
        } catch {
            guard !Task.isCancelled else { return }
            if deck == nil, current?.id == track.id {
                isLoading = false
                isPlaying = false
                errorMessage = error.localizedDescription
                updateNowPlaying()
            }
        }
    }

    /// `direct` deja que AVPlayer pida el archivo por su cuenta: es el plan B si la carga
    /// por tramos falla en algún stream.
    private func asset(for track: Track, refresh: Bool, direct: Bool) async throws -> (asset: AVURLAsset, chunked: Bool) {
        if let file = DownloadStore.shared.fileURL(for: track.id) {
            return (AVURLAsset(url: file), false)
        }
        let stream = try await resolve(track, refresh: refresh)
        if !direct, let chunked = StreamLoader.asset(for: stream, id: track.id) {
            return (chunked, true)
        }
        return (AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers]), false)
    }

    func resolve(_ track: Track, refresh: Bool = false) async throws -> ResolvedStream {
        if !refresh, let cached = streams[track.id], cached.expiresAt.timeIntervalSinceNow > 120 {
            return cached
        }
        guard let session = SessionStore.shared.session else {
            throw ProviderError(message: "Inicia sesión en YouTube Music para reproducir canciones.")
        }
        let payload: [String: Any] = [
            "session": session.providerJSON,
            "track": track.providerJSON,
            "streamQuality": settings.quality.rawValue,
            "refreshStream": refresh,
            // AVPlayer abre AAC en MP4 de forma nativa; Opus en WebM no.
            "audioMimeTypes": ["audio/mp4; codecs=\"mp4a.40.2\"", "audio/mp4; codecs=\"mp4a.40.5\""],
        ]
        let json = try await Provider.object("playback.resolve", payload)
        guard let text = json["url"] as? String, let url = URL(string: text) else {
            throw ProviderError(message: "YouTube no entregó el audio de esta canción.")
        }
        let origin = (json["origin"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.musicOrigin
        let agent = (json["userAgent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.userAgent
        var expires = Date().addingTimeInterval(5 * 3600)
        if let millis = json["expiresAt"] as? Double, millis > 0 {
            expires = Date(timeIntervalSince1970: millis > 1e12 ? millis / 1000 : millis)
        }
        var tracking: PlaybackTracking?
        if let info = json["playbackTracking"] as? [String: Any],
           let playbackUrl = info["playbackUrl"] as? String, !playbackUrl.isEmpty,
           let watchtimeUrl = info["watchtimeUrl"] as? String, !watchtimeUrl.isEmpty {
            tracking = PlaybackTracking(playbackUrl: playbackUrl, watchtimeUrl: watchtimeUrl,
                                        itag: info["itag"] as? Int ?? 140)
        }
        let realDuration = (json["durationSeconds"] as? Double) ?? (json["durationSeconds"] as? Int).map(Double.init) ?? 0
        let stream = ResolvedStream(url: url,
                                    headers: ["User-Agent": agent, "Origin": origin, "Referer": origin + "/"],
                                    expiresAt: expires, tracking: tracking, duration: realDuration,
                                    contentLength: (json["contentLength"] as? NSNumber)?.int64Value ?? 0)
        streams[track.id] = stream
        if streams.count > 16, let oldest = streams.keys.first(where: { $0 != track.id }) {
            streams.removeValue(forKey: oldest)
        }
        return stream
    }

    private func observe(_ deck: Deck, track: Track) {
        guard let item = deck.item else { return }
        deck.observers = [
            item.observe(\.status, options: [.new]) { [weak self, weak deck] item, _ in
                Task { @MainActor in
                    guard let self, let deck, deck.trackId == track.id else { return }
                    switch item.status {
                    case .readyToPlay:
                        deck.ready = true
                        self.clampEnd(of: deck, track: track)
                        if deck === self.active {
                            self.isLoading = false
                            let seconds = self.trueDuration(of: track, item: item)
                            if seconds > 0 { self.duration = seconds }
                            if let target = self.resumeAt {
                                self.resumeAt = nil
                                self.seek(to: target)
                                if self.resumePaused { self.pause() }
                            }
                            self.updateNowPlaying()
                        }
                    case .failed:
                        if !deck.failedOnce {
                            // Una URL rechazada (403/410): pedir una nueva al proveedor, una vez.
                            deck.failedOnce = true
                            self.streams[track.id] = nil
                            if deck === self.active {
                                self.loadTask = Task { [weak self] in
                                    await self?.start(track, on: nil, refresh: true, direct: true)
                                }
                            } else {
                                self.standbyTask = Task { [weak self, weak deck] in
                                    guard let self, let deck else { return }
                                    await self.start(track, on: deck, refresh: true, direct: true)
                                }
                            }
                        } else if deck === self.active {
                            self.isLoading = false
                            self.isPlaying = false
                            self.errorMessage = item.error?.localizedDescription ?? "No se pudo reproducir esta canción."
                        } else {
                            deck.clear()
                        }
                    default:
                        break
                    }
                }
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self, weak deck] item, _ in
                Task { @MainActor in
                    guard let self, let deck, deck === self.active, deck.trackId == track.id else { return }
                    self.isLoading = item.isPlaybackBufferEmpty && self.isPlaying
                }
            },
        ]
    }

    /// Duración verdadera de una canción. Los AAC fragmentados de YouTube hacen que AVPlayer
    /// informe el doble, así que manda la duración que entrega YouTube (o la del catálogo).
    private func trueDuration(of track: Track?, item: AVPlayerItem?) -> Double {
        let reported = item?.duration.seconds ?? .nan
        let known: Double
        if let track, let stream = streams[track.id], stream.duration > 0 {
            known = stream.duration
        } else {
            known = track?.durationSeconds ?? 0
        }
        guard known > 0 else { return reported.isFinite && reported > 0 ? reported : 0 }
        if reported.isFinite, abs(reported - known) <= 3 { return reported }
        return known
    }

    /// Si AVPlayer cree que el archivo es más largo de lo real, hacer que termine donde corresponde.
    private func clampEnd(of deck: Deck, track: Track) {
        guard let item = deck.item else { return }
        let real = trueDuration(of: track, item: item)
        let reported = item.duration.seconds
        if real > 0, reported.isFinite, reported > real + 3 {
            item.forwardPlaybackEndTime = CMTime(seconds: real, preferredTimescale: 600)
        }
    }

    private func attachEndObserver() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        guard let item = active.item else { return }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor in self?.trackEnded() }
        }
    }

    private func trackEnded() {
        guard let id = current?.id, endedTrackId != id || repeatMode == .one else { return }
        endedTrackId = id
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            pause()
            return
        }
        if repeatMode == .one {
            endedTrackId = nil
            seek(to: 0)
            active.player.play()
            return
        }
        next()
    }

    /// Pasa a la siguiente canción, usando la que ya está preparada si se puede.
    private func advance(using prepared: Bool) {
        finishHistory()
        index += 1
        if prepared {
            swapDecks()
            active.player.volume = 1
            active.player.play()
            isLoading = !active.ready
            duration = trueDuration(of: current, item: active.item)
            position = 0
            endedTrackId = nil
            errorMessage = nil
            attachEndObserver()
            standby.clear()
            refreshLike()
            updateNowPlaying()
            saveQueue()
        } else {
            loadCurrent()
        }
    }

    private func swapDecks() {
        let previous = active
        active = standby
        standby = previous
    }

    private func resetStandby() {
        guard !fading else { return }
        standbyTask?.cancel()
        standby.clear()
    }

    /// Prepara la siguiente canción en el reproductor de reserva.
    private func prepareStandby() {
        guard !fading else { return }
        let nextTrack: Track?
        if repeatMode == .one {
            nextTrack = nil
        } else if queue.indices.contains(index + 1) {
            nextTrack = queue[index + 1]
        } else if repeatMode == .all {
            nextTrack = queue.first
        } else {
            nextTrack = nil
        }
        guard let nextTrack, standby.trackId != nextTrack.id else { return }
        standby.clear()
        standby.trackId = nextTrack.id
        standbyTask = Task { [weak self] in
            guard let self else { return }
            await self.start(nextTrack, on: self.standby, refresh: false)
        }
    }

    // MARK: - Reloj interno: posición, crossfade, temporizador, historial

    private func tick() {
        let time = active.player.currentTime().seconds
        if time.isFinite, active.item != nil { position = max(0, time) }
        if active.ready {
            let seconds = trueDuration(of: current, item: active.item)
            if seconds > 0 { duration = seconds }
        }
        if duration > 0 { position = min(position, duration) }

        // Si la carga por tramos no arranca en 15 s, reintentar con la carga directa.
        if let track = current, active.item != nil, !active.ready, active.chunked, !active.failedOnce,
           active.trackId == track.id, Date().timeIntervalSince(active.startedAt) > 15 {
            active.failedOnce = true
            loadTask?.cancel()
            loadTask = Task { [weak self] in await self?.start(track, on: nil, refresh: false, direct: true) }
        }

        if let sleepAt, Date() >= sleepAt {
            self.sleepAt = nil
            pause()
        }

        guard isPlaying, active.ready, duration > 0 else { return }
        let remaining = duration - position

        // Respaldo: si el aviso de fin de AVPlayer no llega, terminar al alcanzar la duración real.
        if remaining <= 0.05, !fading {
            trackEnded()
            return
        }

        // Preparar la siguiente con tiempo, y pedir más canciones si la cola se acaba.
        if remaining < max(45, settings.crossfade + 20) {
            if upcoming.isEmpty, repeatMode == .off, settings.autoplay, !refilling {
                Task { await refill(thenAdvance: false) }
            }
            prepareStandby()
        }

        let fade = settings.crossfade
        if fade > 0, repeatMode != .one, !sleepAtEndOfTrack, !fading,
           remaining <= fade, remaining > 0.3, standby.ready,
           let nextId = standby.trackId,
           nextId == (queue.indices.contains(index + 1) ? queue[index + 1].id : (repeatMode == .all ? queue.first?.id : nil)) {
            beginFade()
        }
        if fading { stepFade() }

        reportHistory()
    }

    private func beginFade() {
        fading = true
        fadeStart = Date()
        standby.player.volume = 0
        standby.player.play()
    }

    private func stepFade() {
        guard let fadeStart else { return }
        let total = max(settings.crossfade, 0.5)
        let progress = min(1, Date().timeIntervalSince(fadeStart) / total)
        // Curva de igual potencia: el volumen total no se hunde a la mitad del cruce.
        active.player.volume = Float(cos(progress * .pi / 2))
        standby.player.volume = Float(sin(progress * .pi / 2))
        if progress >= 1 || active.player.timeControlStatus == .paused { finishFade() }
    }

    private func finishFade() {
        guard fading else { return }
        fading = false
        fadeStart = nil
        let wrapping = !queue.indices.contains(index + 1)
        finishHistory()
        if wrapping { index = -1 }
        active.player.pause()
        index += 1
        swapDecks()
        active.player.volume = 1
        if !isPlaying { active.player.pause() }
        standby.clear()
        attachEndObserver()
        isLoading = !active.ready
        errorMessage = nil
        endedTrackId = nil
        duration = trueDuration(of: current, item: active.item)
        refreshLike()
        updateNowPlaying()
        saveQueue()
    }

    private func reportHistory() {
        guard settings.sendHistory, let track = current, SessionStore.shared.isSignedIn,
              DownloadStore.shared.fileURL(for: track.id) == nil,
              let tracking = streams[track.id]?.tracking else { return }
        if historyTrackId != track.id {
            finishHistory()
            historyTrackId = track.id
            historyCpn = Self.makeCpn()
            historyReported = position
            let cpn = historyCpn, at = position
            Task { await Catalog.history("history.start", tracking: tracking, cpn: cpn, watchTime: at, final: false) }
            return
        }
        if position >= historyReported + 30 || position < historyReported {
            historyReported = position
            let cpn = historyCpn, at = position
            Task { await Catalog.history("history.update", tracking: tracking, cpn: cpn, watchTime: at, final: false) }
        }
    }

    private func finishHistory() {
        guard !historyCpn.isEmpty, let tracking = streams[historyTrackId]?.tracking else {
            historyCpn = ""
            historyTrackId = ""
            return
        }
        let cpn = historyCpn, at = position
        historyCpn = ""
        historyTrackId = ""
        Task { await Catalog.history("history.update", tracking: tracking, cpn: cpn, watchTime: at, final: true) }
    }

    private static func makeCpn() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    /// Fin de la cola: si Autoplay está activo, sumar canciones parecidas.
    private func refill(thenAdvance: Bool) async {
        guard settings.autoplay, let last = queue.last, !refilling else {
            if thenAdvance { pause(); seek(to: 0) }
            return
        }
        refilling = true
        defer { refilling = false }
        do {
            let known = Set(queue.map(\.id))
            let more = try await Catalog.upNext(after: last).filter { !known.contains($0.id) }
            guard !more.isEmpty else { if thenAdvance { pause() }; return }
            queue.append(contentsOf: more.prefix(25))
            saveQueue()
            if thenAdvance { advance(using: false) }
        } catch {
            if thenAdvance {
                pause()
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Guardar la cola entre aperturas

    private var queueURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("queue.json")
    }

    private struct SavedQueue: Codable {
        let tracks: [Track]
        let index: Int
    }

    private func saveQueue() {
        let saved = SavedQueue(tracks: Array(queue.prefix(300)), index: min(index, max(0, min(queue.count, 300) - 1)))
        let url = queueURL
        Task.detached {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: queueURL),
              let saved = try? JSONDecoder().decode(SavedQueue.self, from: data),
              saved.tracks.indices.contains(saved.index) else { return }
        queue = saved.tracks
        index = saved.index
        duration = current?.durationSeconds ?? 0
    }

    // MARK: - Sistema: sesión de audio, pantalla de bloqueo

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            isPlaying = false
            if fading { finishFade() }
            updateNowPlaying()
        } else if let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            resume()
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        center.likeCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork, artwork.id == track.id {
            info[MPMediaItemPropertyArtwork] = artwork.image
        } else {
            loadArtwork(for: track)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) {
        guard let url = track.largeThumbnail else { return }
        Task { [weak self] in
            guard let response = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: response.0) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard let self, self.current?.id == track.id else { return }
                self.artwork = (track.id, artwork)
                self.updateNowPlaying()
            }
        }
    }
}
