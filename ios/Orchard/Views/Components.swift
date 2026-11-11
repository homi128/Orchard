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
    let track: Track
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.thumbnail, fallback: track.fallbackThumbnail, size: 48, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if track.explicit {
                Image(systemName: "e.square.fill").foregroundStyle(.secondary).font(.caption)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Menú de una canción: tocar reproduce; mantener presionado ofrece la cola.
struct TrackActions: ViewModifier {
    @EnvironmentObject private var player: Player
    let track: Track

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { player.playNext(track) } label: { Label("Reproducir a continuación", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("Agregar a la cola", systemImage: "text.append") }
        }
        .swipeActions(edge: .leading) {
            Button { player.playNext(track) } label: { Label("Siguiente", systemImage: "text.insert") }
                .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing) {
            Button { player.addToQueue(track) } label: { Label("A la cola", systemImage: "text.append") }
                .tint(.indigo)
        }
    }
}

extension View {
    func trackActions(_ track: Track) -> some View { modifier(TrackActions(track: track)) }
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

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}
