import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var sessions: SessionStore
    @State private var playlists: [CatalogItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            if !sessions.isSignedIn {
                ScrollView { SignInPrompt(message: "Inicia sesión en YouTube Music para ver tus playlists y reproducir canciones.").padding(.top, 80) }
            } else {
                List {
                    if let error {
                        ErrorBanner(message: error) { Task { await load() } }
                    }
                    Section("Tus playlists") {
                        if loading && playlists.isEmpty {
                            ProgressView()
                        }
                        ForEach(playlists) { item in
                            NavigationLink(value: item) {
                                HStack(spacing: 12) {
                                    Artwork(url: item.thumbnail, size: 52, corner: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    Section("Cuenta") {
                        Button("Cerrar sesión", role: .destructive) { confirmSignOut = true }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Biblioteca")
        .navigationDestination(for: CatalogItem.self) { CollectionView(item: $0) }
        .task(id: sessions.session?.cookie) {
            if sessions.isSignedIn { await load() } else { playlists = [] }
        }
        .confirmationDialog("¿Cerrar la sesión de YouTube Music?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { sessions.signOut() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            playlists = try await Catalog.playlists()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Playlist o álbum: lista de canciones con Reproducir y Aleatorio.
struct CollectionView: View {
    @EnvironmentObject private var player: Player
    let item: CatalogItem
    @State private var title = ""
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Artwork(url: item.thumbnail, size: 200, corner: 12)
                    Text(title.isEmpty ? item.title : title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button {
                            player.play(tracks)
                        } label: { Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button {
                            player.play(tracks.shuffled())
                        } label: { Label("Aleatorio", systemImage: "shuffle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    .disabled(tracks.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let error {
                ErrorBanner(message: error) { Task { await load() } }
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                Button {
                    player.play(tracks, startAt: offset)
                } label: {
                    TrackRow(track: track, isCurrent: player.current?.id == track.id)
                }
                .buttonStyle(.plain)
                .trackActions(track)
            }
        }
        .listStyle(.plain)
        .overlay { if loading && tracks.isEmpty { ProgressView() } }
        .navigationTitle(title.isEmpty ? item.title : title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await Catalog.collection(item)
            title = result.title
            tracks = result.tracks
            error = result.tracks.isEmpty ? "No encontré canciones aquí." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
