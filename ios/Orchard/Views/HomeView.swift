import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var tint: ArtworkTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?
    @State private var revealed = false

    /// Los primeros elementos del primer estante van arriba como accesos rápidos.
    private var quick: [CatalogItem] {
        guard let first = shelves.first, first.items.count >= 4 else { return [] }
        return Array(first.items.prefix(6))
    }

    private var rest: [Shelf] { quick.isEmpty ? shelves : Array(shelves.dropFirst()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(greeting)
                        .font(Theme.display(34))
                        .padding(.horizontal)
                    SearchLauncher()
                        .padding(.horizontal)
                }

                if !sessions.isSignedIn {
                    SignInPrompt().padding(.top, 40)
                } else if loading && shelves.isEmpty {
                    skeleton
                } else if let error, shelves.isEmpty {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    if !quick.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(quick) { item in
                                ItemLink(item: item, siblings: quick) { QuickTile(item: item) }
                            }
                        }
                        .padding(.horizontal)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 14)
                    }
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(Array(rest.enumerated()), id: \.element.id) { index, shelf in
                            ShelfView(shelf: shelf)
                                .opacity(revealed ? 1 : 0)
                                .offset(y: revealed ? 0 : 18)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.06 * Double(min(index + 1, 5))),
                                           value: revealed)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .background(backdrop.ignoresSafeArea())
        .refreshable { await load() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: sessions.session?.cookie) {
            if sessions.isSignedIn { await load() } else { shelves = [] }
        }
    }

    /// Un resplandor del color de lo que suena, arriba de la pantalla.
    private var backdrop: some View {
        ZStack(alignment: .top) {
            Theme.base
            LinearGradient(colors: [tint.color.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Buenos días"
        case 12..<20: return "Buenas tardes"
        default: return "Buenas noches"
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in Skeleton(height: 58, corner: 12) }
            }
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    Skeleton(width: 180, height: 22, corner: 6)
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in Skeleton(width: 150, height: 150, corner: 14) }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            shelves = try await Catalog.home()
            error = nil
            if !revealed {
                if reduceMotion { revealed = true } else { withAnimation(.easeOut(duration: 0.45)) { revealed = true } }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Acceso rápido: carátula pequeña y título, en una pastilla.
struct QuickTile: View {
    @EnvironmentObject private var player: Player
    let item: CatalogItem

    private var isCurrent: Bool { item.track != nil && item.track?.id == player.current?.id }

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: item.thumbnail, fallback: item.track?.fallbackThumbnail, size: 58,
                    corner: item.kind == .artist ? 29 : 0)
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(isCurrent ? Theme.accent : .primary)
            Spacer(minLength: 4)
            if isCurrent {
                EqualizerBars(animating: player.isPlaying, color: Theme.accent).padding(.trailing, 10)
            }
        }
        .frame(height: 58)
        .background(Color.white.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
