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
    @State private var scrubbing: Double?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Reproduciendo").tag(0)
                Text("A continuación").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if tab == 0 { nowPlaying } else { queue }
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

    private var nowPlaying: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            if let track = player.current {
                Artwork(url: track.largeThumbnail, fallback: track.fallbackThumbnail, corner: 14)
                    .frame(maxWidth: 340)
                    .shadow(radius: 24, y: 12)
                    .padding(.horizontal, 28)
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.isPlaying)

                VStack(spacing: 4) {
                    Text(track.title).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(track.artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal)

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
                        Text(formatTime(player.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 44) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                        .accessibilityLabel("Anterior")
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
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                        .accessibilityLabel("Siguiente")
                }
                .foregroundStyle(.white)
            } else {
                Text("Nada sonando").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 24)
    }

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
                Toggle("Autoplay: seguir con canciones parecidas", isOn: $player.autoplay)
                    .font(.footnote)
                    .padding(.top, 8)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
    }
}
