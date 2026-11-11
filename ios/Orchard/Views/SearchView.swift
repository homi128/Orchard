import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var sessions: SessionStore
    @State private var query = ""
    @State private var results: [CatalogItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searched = false

    var body: some View {
        List {
            if !sessions.isSignedIn && searched {
                Text("Puedes buscar sin cuenta, pero para reproducir tienes que iniciar sesión en Biblioteca.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                ErrorBanner(message: error) { Task { await search() } }
                    .listRowBackground(Color.clear)
            }
            let tracks = results.compactMap(\.track)
            ForEach(results) { item in
                if let track = item.track {
                    Button {
                        player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                    } label: {
                        TrackRow(track: track, isCurrent: player.current?.id == track.id)
                    }
                    .buttonStyle(.plain)
                    .trackActions(track)
                } else if item.browseId != nil, item.kind != .artist {
                    NavigationLink(value: item) {
                        HStack(spacing: 12) {
                            Artwork(url: item.thumbnail, size: 48, corner: 6)
                            VStack(alignment: .leading) {
                                Text(item.title).lineLimit(1)
                                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading {
                ProgressView()
            } else if searched && results.isEmpty && error == nil {
                Text("No encontré canciones con eso. Prueba con otro nombre.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else if !searched {
                Text("Busca canciones o artistas.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Buscar")
        .navigationDestination(for: CatalogItem.self) { CollectionView(item: $0) }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Canciones, artistas")
        .onSubmit(of: .search) { Task { await search() } }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        loading = true
        error = nil
        defer { loading = false; searched = true }
        do {
            results = try await Catalog.search(text)
        } catch {
            results = []
            self.error = error.localizedDescription
        }
    }
}
