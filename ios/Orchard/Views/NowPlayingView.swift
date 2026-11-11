import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: Player
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Artwork(url: track.thumbnail, fallback: track.fallbackThumbnail, size: 44, corner: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.errorMessage ?? track.artist)
                        .font(.caption)
                        .foregroundStyle(player.errorMessage == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.isLoading {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                }
                .accessibilityLabel("Siguiente")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let progress = player.duration > 0 ? min(1, player.position / player.duration) : 0
                    Capsule().fill(Theme.accent)
                        .frame(width: geometry.size.width * progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { showNowPlaying = true }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var ui: AppUI
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Reproduciendo").tag(0)
                Text("Letra").tag(1)
                Text("A continuación").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            switch tab {
            case 0: nowPlaying
            case 1: LyricsPanel()
            default: queue
            }
        }
        .background(background.ignoresSafeArea())
    }

    private var background: some View {
        ZStack {
            Color.black
            if let track = player.current {
                Artwork(url: track.largeThumbnail, fallback: track.fallbackThumbnail, corner: 0)
                    .blur(radius: 60)
                    .opacity(0.45)
                    .scaleEffect(1.4)
            }
        }
    }

    // MARK: Reproduciendo

    private var nowPlaying: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            if let track = player.current {
                Artwork(url: track.largeThumbnail, fallback: track.fallbackThumbnail, corner: 14)
                    .frame(maxWidth: 340)
                    .shadow(radius: 24, y: 12)
                    .padding(.horizontal, 28)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.isPlaying)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.title2.weight(.bold)).lineLimit(2)
                        Text(track.artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if sessions.isSignedIn {
                        Button { player.toggleLike() } label: {
                            Image(systemName: player.liked ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(player.liked ? Theme.accent : .white)
                        }
                        .accessibilityLabel(player.liked ? "Quitar me gusta" : "Me gusta")
                    }
                    Menu {
                        TrackMenuItems(track: track)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title2).foregroundStyle(.white)
                    }
                    .accessibilityLabel("Más opciones")
                }
                .padding(.horizontal, 24)

                if let message = player.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
                }

                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { scrubbing ?? player.position },
                        set: { scrubbing = $0 }
                    ), in: 0...max(player.duration, 1)) { editing in
                        if !editing, let value = scrubbing {
                            player.seek(to: value)
                            scrubbing = nil
                        }
                    }
                    HStack {
                        Text(formatTime(scrubbing ?? player.position))
                        Spacer()
                        Text("-" + formatTime(max(0, player.duration - (scrubbing ?? player.position))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.title3)
                            .foregroundStyle(player.shuffle ? Theme.accent : .white.opacity(0.7))
                    }
                    .accessibilityLabel(player.shuffle ? "Desactivar aleatorio" : "Aleatorio")
                    Spacer()
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                        .accessibilityLabel("Anterior")
                    Spacer()
                    Button { player.toggle() } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 72, height: 72)
                            if player.isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title)
                                    .foregroundStyle(.black)
                            }
                        }
                    }
                    .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")
                    Spacer()
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                        .accessibilityLabel("Siguiente")
                    Spacer()
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode.icon).font(.title3)
                            .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.7) : Theme.accent)
                    }
                    .accessibilityLabel("Repetir")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)

                HStack {
                    sleepMenu
                    Spacer()
                    if settings.crossfade > 0 {
                        Label("Crossfade \(Int(settings.crossfade)) s", systemImage: "wave.3.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    downloadButton(for: track)
                }
                .padding(.horizontal, 28)
            } else {
                Text("Nada sonando").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
    }

    private var sleepMenu: some View {
        Menu {
            if player.sleepAt != nil || player.sleepAtEndOfTrack {
                Button("Cancelar temporizador", role: .destructive) { player.cancelSleep() }
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) minutos") { player.sleep(after: minutes); ui.show("La música se detendrá en \(minutes) min") }
            }
            Button("Al terminar esta canción") { player.sleepAtEndOfCurrentTrack() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                if let at = player.sleepAt {
                    Text(at, style: .timer).monospacedDigit()
                } else if player.sleepAtEndOfTrack {
                    Text("Fin")
                }
            }
            .font(.callout)
            .foregroundStyle(player.sleepAt != nil || player.sleepAtEndOfTrack ? Theme.accent : .white.opacity(0.7))
        }
        .accessibilityLabel("Temporizador de apagado")
    }

    @ViewBuilder
    private func downloadButton(for track: Track) -> some View {
        if downloads.isDownloaded(track.id) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                .accessibilityLabel("Descargada")
        } else if let value = downloads.progress[track.id] {
            ProgressView(value: value).frame(width: 28)
        } else {
            Button { downloads.download(track) } label: {
                Image(systemName: "arrow.down.circle").foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel("Descargar")
        }
    }

    // MARK: Cola

    private var queue: some View {
        List {
            if let current = player.current {
                Section("Sonando") {
                    TrackRow(track: current, isCurrent: true)
                }
            }
            Section {
                ForEach(Array(player.upcoming.enumerated()), id: \.offset) { offset, track in
                    TrackRow(track: track)
                        .onTapGesture { player.jump(toQueueIndex: player.index + 1 + offset) }
                }
                .onMove { player.moveUpcoming(from: $0, to: $1) }
                .onDelete { player.removeUpcoming(at: $0) }
            } header: {
                HStack {
                    Text("A continuación")
                    Spacer()
                    if !player.upcoming.isEmpty {
                        Button("Vaciar") { player.clearUpcoming() }.font(.caption)
                    }
                }
            } footer: {
                Toggle("Autoplay: seguir con canciones parecidas", isOn: $settings.autoplay)
                    .font(.footnote)
                    .padding(.top, 8)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
    }
}

/// Letra de la canción actual; si está sincronizada, sigue la música y tocar una línea salta ahí.
struct LyricsPanel: View {
    @EnvironmentObject private var player: Player
    @State private var result: LyricsResult?
    @State private var loading = false

    private var activeLine: Int? {
        guard let result, result.synced else { return nil }
        let now = player.position + 0.25
        return result.lines.last(where: { ($0.time ?? .infinity) <= now })?.id
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(result.lines) { line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(color(for: line, synced: result.synced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                                    .onTapGesture {
                                        if let time = line.time { player.seek(to: time) }
                                    }
                            }
                            Text("Letra: \(result.source)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 40)
                    }
                    .onChange(of: activeLine) { line in
                        guard let line else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(line, anchor: .center) }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "text.quote").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No encontré la letra de esta canción.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: player.current?.id) {
            guard let track = player.current else { result = nil; return }
            loading = true
            result = await Lyrics.load(for: track)
            loading = false
        }
    }

    private func color(for line: LyricLine, synced: Bool) -> Color {
        guard synced, let active = activeLine else { return synced ? .white.opacity(0.4) : .white }
        return line.id == active ? .white : .white.opacity(line.id < active ? 0.35 : 0.5)
    }
}
