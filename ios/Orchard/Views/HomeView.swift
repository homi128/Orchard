import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var player: Player
    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if !sessions.isSignedIn {
                ScrollView { SignInPrompt().padding(.top, 80) }
            } else if loading && shelves.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, shelves.isEmpty {
                ErrorBanner(message: error) { Task { await load() } }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(shelves) { shelf in
                            ShelfView(shelf: shelf)
                        }
                    }
                    .padding(.vertical)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Inicio")
        .navigationDestination(for: CatalogItem.self) { CollectionView(item: $0) }
        .task(id: sessions.session?.cookie) {
            if sessions.isSignedIn { await load() } else { shelves = [] }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            shelves = try await Catalog.home()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

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
                        card(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func card(_ item: CatalogItem) -> some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            Artwork(url: item.thumbnail, fallback: item.track?.fallbackThumbnail, size: 150, corner: item.kind == .artist ? 75 : 10)
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)

        if let track = item.track {
            Button {
                let tracks = shelf.items.compactMap(\.track)
                player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
            } label: { content }
            .buttonStyle(.plain)
            .contextMenu {
                Button { player.playNext(track) } label: { Label("Reproducir a continuación", systemImage: "text.insert") }
                Button { player.addToQueue(track) } label: { Label("Agregar a la cola", systemImage: "text.append") }
            }
        } else if item.browseId != nil, item.kind != .artist {
            NavigationLink(value: item) { content }.buttonStyle(.plain)
        } else {
            content.opacity(0.6)
        }
    }
}
