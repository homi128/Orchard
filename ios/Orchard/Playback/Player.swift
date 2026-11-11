import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Un stream listo para AVPlayer, como ResolvedStream en Android.
struct ResolvedStream {
    let url: URL
    let headers: [String: String]
    let expiresAt: Date
}

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
    @Published var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upcoming: [Track] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemObservers: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var streams: [String: ResolvedStream] = [:]
    private var loadTask: Task<Void, Never>?
    private var refilling = false
    private var artwork: (id: String, image: MPMediaItemArtwork)?

    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    private static let musicOrigin = "https://music.youtube.com"

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                               queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    // MARK: - Controles

    func play(_ tracks: [Track], startAt start: Int = 0) {
        guard tracks.indices.contains(start) else { return }
        queue = tracks
        index = start
        load(current: true)
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.insert(track, at: min(index + 1, queue.count))
    }

    func addToQueue(_ track: Track) {
        if queue.isEmpty { play([track]); return }
        queue.append(track)
    }

    func toggle() {
        if player.currentItem == nil {
            if current != nil { load(current: true) }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        if queue.indices.contains(index + 1) {
            index += 1
            load(current: true)
        } else {
            Task { await refillAndAdvance() }
        }
    }

    func previous() {
        if position > 4 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        load(current: true)
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        position = max(0, seconds)
    }

    func jump(toQueueIndex newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        load(current: true)
    }

    /// Mueve canciones de "a continuación" (índices relativos a `upcoming`).
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var rest = upcoming
        rest.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + rest
    }

    func removeUpcoming(at offsets: IndexSet) {
        var rest = upcoming
        rest.remove(atOffsets: offsets)
        queue = Array(queue[...index]) + rest
    }

    func clearUpcoming() {
        guard !queue.isEmpty else { return }
        queue = Array(queue[...index])
    }

    // MARK: - Carga del stream

    private func load(current _: Bool) {
        guard let track = current else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        position = 0
        duration = track.durationSeconds
        player.pause()
        updateNowPlaying()
        loadTask = Task { [weak self] in
            await self?.start(track, refresh: false)
        }
    }

    private func start(_ track: Track, refresh: Bool) async {
        do {
            let stream = try await resolve(track, refresh: refresh)
            guard !Task.isCancelled, current?.id == track.id else { return }
            let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 30
            observe(item, track: track, refreshed: refresh)
            player.replaceCurrentItem(with: item)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            updateNowPlaying()
            prefetchNext()
        } catch {
            guard !Task.isCancelled, current?.id == track.id else { return }
            isLoading = false
            isPlaying = false
            errorMessage = error.localizedDescription
            updateNowPlaying()
        }
    }

    private func resolve(_ track: Track, refresh: Bool) async throws -> ResolvedStream {
        if !refresh, let cached = streams[track.id], cached.expiresAt.timeIntervalSinceNow > 120 {
            return cached
        }
        guard let session = SessionStore.shared.session else {
            throw ProviderError(message: "Inicia sesión en YouTube Music para reproducir canciones.")
        }
        let payload: [String: Any] = [
            "session": session.providerJSON,
            "track": track.providerJSON,
            "streamQuality": "high",
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
        let stream = ResolvedStream(url: url,
                                    headers: ["User-Agent": agent, "Origin": origin, "Referer": origin + "/"],
                                    expiresAt: expires)
        streams[track.id] = stream
        if streams.count > 12 { streams.removeValue(forKey: streams.keys.first!) }
        return stream
    }

    private func prefetchNext() {
        guard let next = upcoming.first, streams[next.id] == nil else { return }
        Task { [weak self] in _ = try? await self?.resolve(next, refresh: false) }
    }

    private func observe(_ item: AVPlayerItem, track: Track, refreshed: Bool) {
        itemObservers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.current?.id == track.id else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.isLoading = false
                        let seconds = item.duration.seconds
                        if seconds.isFinite, seconds > 0 { self.duration = seconds }
                        self.updateNowPlaying()
                    case .failed:
                        if !refreshed {
                            // Una URL rechazada (403/410): pedir una nueva al proveedor, una vez.
                            self.streams[track.id] = nil
                            self.loadTask = Task { [weak self] in await self?.start(track, refresh: true) }
                        } else {
                            self.isLoading = false
                            self.isPlaying = false
                            self.errorMessage = item.error?.localizedDescription ?? "No se pudo reproducir esta canción."
                        }
                    default:
                        break
                    }
                }
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.current?.id == track.id else { return }
                    self.isLoading = item.isPlaybackBufferEmpty && self.isPlaying
                }
            },
        ]
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    /// Fin de la cola: si Autoplay está activo, sumar canciones parecidas y seguir.
    private func refillAndAdvance() async {
        guard autoplay, let last = queue.last, !refilling else {
            pause()
            seek(to: 0)
            return
        }
        refilling = true
        defer { refilling = false }
        do {
            let known = Set(queue.map(\.id))
            let more = try await Catalog.upNext(after: last).filter { !known.contains($0.id) }
            guard !more.isEmpty else { pause(); return }
            queue.append(contentsOf: more.prefix(25))
            index += 1
            load(current: true)
        } catch {
            pause()
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sistema: sesión de audio, pantalla de bloqueo

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            isPlaying = false
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
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
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
