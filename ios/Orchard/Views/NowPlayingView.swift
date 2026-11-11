import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var tint: ArtworkTint
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Artwork(url: track.thumbnail, fallback: track.fallbackThumbnail, size: 44, corner: 9)
                    .id(track.id)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
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
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.color.opacity(0.38)))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: track.id)
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let progress = player.duration > 0 ? min(1, player.position / player.duration) : 0
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: geometry.size.width * progress, height: 2)
                        .animation(.linear(duration: 0.25), value: progress)
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
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
    @EnvironmentObject private var tint: ArtworkTint
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubbing: Double?
    @State private var drift = false
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

    /// El color de la carátula llena la pantalla y se mueve muy despacio.
    private var background: some View {
        ZStack {
            Theme.base
            LinearGradient(colors: [tint.color, tint.color.opacity(0.35), Theme.base],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(tint.color)
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .opacity(0.55)
                .offset(x: drift ? 110 : -110, y: drift ? -220 : -120)
            Circle()
                .fill(Theme.peach)
                .frame(width: 260, height: 260)
                .blur(radius: 130)
                .opacity(0.16)
                .offset(x: drift ? -120 : 100, y: drift ? 260 : 180)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    // MARK: Reproduciendo

    private var nowPlaying: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            if let track = player.current {
                Artwork(url: track.largeThumbnail, fallback: track.fallbackThumbnail, corner: 22)
                    .frame(maxWidth: 350)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
                    .padding(.horizontal, 26)
                    .scaleEffect(player.isPlaying ? 1 : 0.86)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                    .id(track.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                            removal: .opacity))

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(Theme.display(24, weight: .bold)).lineLimit(2)
                        Text(track.artist).font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if sessions.isSignedIn {
                        Button { player.toggleLike() } label: {
                            Image(systemName: player.liked ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(player.liked ? Theme.peach : .white)
                                .scaleEffect(player.liked ? 1.15 : 1)
                                .animation(.spring(response: 0.3, dampingFraction: 0.45), value: player.liked)
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

                VStack(spacing: 2) {
                    Scrubber(position: player.position, duration: player.duration,
                             onSeek: { player.seek(to: $0) }, scrubbing: $scrubbing)
                    HStack {
                        Text(formatTime(scrubbing ?? player.position))
                        Spacer()
                        Text("-" + formatTime(max(0, player.duration - (scrubbing ?? player.position))))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 26)

                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.title3)
                            .foregroundStyle(player.shuffle ? Theme.accent : .white.opacity(0.7))
                    }
                    .accessibilityLabel(player.shuffle ? "Desactivar aleatorio" : "Aleatorio")
                    Spacer()
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                        .buttonStyle(PressableStyle(scale: 0.85))
                        .accessibilityLabel("Anterior")
                    Spacer()
                    Button { player.toggle() } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 76, height: 76)
                                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                            if player.isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title)
                                    .foregroundStyle(.black)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel(player.isPlaying ? "Pausar" : "Reproducir")
                    Spacer()
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                        .buttonStyle(PressableStyle(scale: 0.85))
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
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.current?.id)
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
                                    .font(Theme.display(26, weight: .bold))
                                    .foregroundStyle(color(for: line, synced: result.synced))
                                    .scaleEffect(result.synced && line.id == activeLine ? 1 : 0.94, anchor: .leading)
                                    .blur(radius: result.synced && line.id != activeLine ? 0.6 : 0)
                                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: activeLine)
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
