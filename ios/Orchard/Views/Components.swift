import SwiftUI

/// Carátula con respaldo: si la imagen principal falla, usa la de YouTube; si no, un cuadro neutro.
struct Artwork: View {
    let url: URL?
    var fallback: URL? = nil
    var size: CGFloat? = nil
    var corner: CGFloat = 8

    @State private var useFallback = false

    var body: some View {
        let source = useFallback ? fallback : (url ?? fallback)
        AsyncImage(url: source) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                placeholder.onAppear { if !useFallback, fallback != nil, url != nil { useFallback = true } }
            default:
                placeholder
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }
}

struct TrackRow: View {
    @EnvironmentObject private var downloads: DownloadStore
    let track: Track
    var isCurrent = false
    var number: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else {
                Artwork(url: track.thumbnail, fallback: track.fallbackThumbnail, size: 48, corner: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if track.explicit {
                        Image(systemName: "e.square.fill").font(.caption2)
                    }
                    if downloads.isDownloaded(track.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Theme.accent)
                    } else if let value = downloads.progress[track.id] {
                        ProgressView(value: value).frame(width: 28)
                    }
                    Text(track.artist).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if track.durationSeconds > 0 {
                Text(formatTime(track.durationSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Acciones de una canción: menú al mantener presionado y deslizar en listas.
struct TrackActions: ViewModifier {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var ui: AppUI
    @EnvironmentObject private var sessions: SessionStore
    let track: Track
    var swipes = true

    func body(content: Content) -> some View {
        let base = content.contextMenu { TrackMenuItems(track: track) }
        if swipes {
            base
                .swipeActions(edge: .leading) {
                    Button {
                        player.playNext(track)
                        ui.show("Sonará a continuación")
                    } label: { Label("Siguiente", systemImage: "text.insert") }
                        .tint(Theme.accent)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        player.addToQueue(track)
                        ui.show("Agregada a la cola")
                    } label: { Label("A la cola", systemImage: "text.append") }
                        .tint(.indigo)
                }
        } else {
            base
        }
    }
}

struct TrackMenuItems: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var ui: AppUI
    @EnvironmentObject private var sessions: SessionStore
    let track: Track

    var body: some View {
        Button {
            player.playNext(track)
            ui.show("Sonará a continuación")
        } label: { Label("Reproducir a continuación", systemImage: "text.insert") }
        Button {
            player.addToQueue(track)
            ui.show("Agregada a la cola")
        } label: { Label("Agregar a la cola", systemImage: "text.append") }
        Button {
            Task {
                if let more = try? await Catalog.upNext(after: track) {
                    player.play([track] + more)
                }
            }
        } label: { Label("Iniciar radio", systemImage: "dot.radiowaves.left.and.right") }
        if sessions.isSignedIn {
            Button { ui.addToPlaylist = track } label: { Label("Agregar a una playlist", systemImage: "plus.square.on.square") }
        }
        if downloads.isDownloaded(track.id) {
            Button(role: .destructive) { downloads.delete(track.id) } label: {
                Label("Borrar descarga", systemImage: "trash")
            }
        } else if downloads.progress[track.id] != nil {
            Button { downloads.cancel(track.id) } label: { Label("Cancelar descarga", systemImage: "xmark.circle") }
        } else {
            Button { downloads.download(track) } label: { Label("Descargar", systemImage: "arrow.down.circle") }
        }
        if let url = URL(string: "https://music.youtube.com/watch?v=\(track.id)"), track.id.count == 11 {
            ShareLink(item: url) { Label("Compartir", systemImage: "square.and.arrow.up") }
        }
    }
}

extension View {
    func trackActions(_ track: Track, swipes: Bool = true) -> some View {
        modifier(TrackActions(track: track, swipes: swipes))
    }
}

/// Tarjeta cuadrada para estantes horizontales.
struct ItemCard: View {
    let item: CatalogItem
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 6) {
            Artwork(url: item.thumbnail, fallback: item.track?.fallbackThumbnail, size: size,
                    corner: item.kind == .artist ? size / 2 : 10)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(item.kind == .artist ? .center : .leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: size, alignment: item.kind == .artist ? .center : .leading)
    }
}

/// Estante horizontal: tocar una canción la reproduce; lo demás abre su página.
struct ShelfView: View {
    @EnvironmentObject private var player: Player
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !shelf.title.isEmpty {
                Text(shelf.title)
                    .font(.title3.weight(.bold))
                    .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        ItemLink(item: item, siblings: shelf.items) { ItemCard(item: item) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Envuelve una fila o tarjeta: canción → reproducir, colección/artista → abrir.
struct ItemLink<Label: View>: View {
    @EnvironmentObject private var player: Player
    let item: CatalogItem
    var siblings: [CatalogItem] = []
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let track = item.track {
            Button {
                let tracks = siblings.compactMap(\.track)
                if tracks.contains(track) {
                    player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                } else {
                    player.play([track])
                }
            } label: { label() }
            .buttonStyle(.plain)
            .contextMenu { TrackMenuItems(track: track) }
        } else if item.browseId != nil {
            NavigationLink(value: Route.item(item)) { label() }
                .buttonStyle(.plain)
        } else {
            label().opacity(0.6)
        }
    }
}

struct SignInPrompt: View {
    @State private var showLogin = false
    var message = "Inicia sesión en YouTube Music para ver tus recomendaciones y reproducir canciones."

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button("Iniciar sesión") { showLogin = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showLogin) { LoginView() }
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let retry {
                Button("Reintentar", action: retry).buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Barra que parece un buscador; al tocarla abre la pestaña Buscar.
struct SearchLauncher: View {
    @EnvironmentObject private var ui: AppUI

    var body: some View {
        Button { ui.openSearch() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Canciones, artistas, álbumes")
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Buscar")
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
