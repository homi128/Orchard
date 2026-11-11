import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: AppUI

    @State private var query = ""
    @State private var submitted = ""
    @State private var filter: SearchFilter = .all
    @State private var results = SearchResults()
    @State private var suggestions: [String] = []
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var typing: Bool { focused && query != submitted }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !submitted.isEmpty && !typing {
                filterBar
            }
            List {
                if typing || submitted.isEmpty {
                    suggestionRows
                } else {
                    resultRows
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if loading && results.isEmpty && !typing {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Buscar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if ui.focusSearch { focused = true; ui.focusSearch = false } }
        .onChange(of: ui.focusSearch) { value in
            if value { focused = true; ui.focusSearch = false }
        }
        .task(id: query) { await loadSuggestions() }
        .task(id: "\(submitted)|\(filter.rawValue)") { await search() }
    }

    // MARK: Barra

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Canciones, artistas, álbumes", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { submit(query) }
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Borrar")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if focused {
                Button("Cancelar") {
                    focused = false
                    query = submitted
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { option in
                    Button { filter = option } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(filter == option ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
                            .foregroundStyle(filter == option ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: Sugerencias y recientes

    @ViewBuilder
    private var suggestionRows: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            if settings.recentSearches.isEmpty {
                Text("Busca canciones, artistas, álbumes o playlists.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(settings.recentSearches, id: \.self) { recent in
                        Button { submit(recent) } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in settings.recentSearches.remove(atOffsets: offsets) }
                } header: {
                    HStack {
                        Text("Recientes")
                        Spacer()
                        Button("Borrar") { settings.recentSearches = [] }.font(.caption)
                    }
                }
            }
        } else {
            Button { submit(query) } label: {
                Label("Buscar \"\(query)\"", systemImage: "magnifyingglass").foregroundStyle(.primary)
            }
            ForEach(suggestions, id: \.self) { suggestion in
                HStack {
                    Button { submit(suggestion) } label: {
                        Label(suggestion, systemImage: "magnifyingglass")
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { query = suggestion + " " } label: {
                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Completar con \(suggestion)")
                }
            }
        }
    }

    // MARK: Resultados

    @ViewBuilder
    private var resultRows: some View {
        if !sessions.isSignedIn {
            Text("Puedes buscar sin cuenta, pero para reproducir tienes que iniciar sesión en Biblioteca.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let error {
            ErrorBanner(message: error) { Task { await search() } }
                .listRowBackground(Color.clear)
        } else if !loading && results.isEmpty {
            Text("No encontré nada con \"\(submitted)\". Prueba con otro nombre.")
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }

        if filter == .all {
            if !results.top.isEmpty {
                Section("Mejor resultado") { itemRows(results.top.prefix(3).map { $0 }) }
            }
            if !results.songs.isEmpty {
                Section("Canciones") { trackRows(Array(results.songs.prefix(6)), all: results.songs) }
            }
            if !results.artists.isEmpty {
                Section("Artistas") { carousel(results.artists) }
            }
            if !results.albums.isEmpty {
                Section("Álbumes") { carousel(results.albums) }
            }
            if !results.playlists.isEmpty {
                Section("Playlists") { carousel(results.playlists) }
            }
            if !results.videos.isEmpty {
                Section("Videos") { trackRows(Array(results.videos.prefix(5)), all: results.videos) }
            }
        } else {
            switch filter {
            case .songs: trackRows(results.songs + results.top.compactMap(\.track), all: results.songs)
            case .videos: trackRows(results.videos + results.top.compactMap(\.track), all: results.videos)
            case .albums: itemRows(results.albums + results.top.filter { $0.kind != .track })
            case .artists: itemRows(results.artists + results.top.filter { $0.kind == .artist })
            case .playlists: itemRows(results.playlists + results.top.filter { $0.kind != .track })
            case .all: EmptyView()
            }
        }
    }

    private func trackRows(_ tracks: [Track], all: [Track]) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
            Button {
                let list = all.contains(track) ? all : tracks
                player.play(list, startAt: list.firstIndex(of: track) ?? 0)
            } label: {
                TrackRow(track: track, isCurrent: player.current?.id == track.id)
            }
            .buttonStyle(.plain)
            .trackActions(track)
        }
    }

    private func itemRows(_ items: [CatalogItem]) -> some View {
        ForEach(items) { item in
            ItemLink(item: item, siblings: items) {
                HStack(spacing: 12) {
                    Artwork(url: item.thumbnail, fallback: item.track?.fallbackThumbnail, size: 52,
                            corner: item.kind == .artist ? 26 : 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1)
                        Text(subtitle(for: item)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.track == nil {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
        }
    }

    private func carousel(_ items: [CatalogItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    ItemLink(item: item, siblings: items) { ItemCard(item: item, size: 130) }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    private func subtitle(for item: CatalogItem) -> String {
        let kind: String
        switch item.kind {
        case .track: kind = "Canción"
        case .album: kind = "Álbum"
        case .playlist: kind = "Playlist"
        case .artist: kind = "Artista"
        case .other: kind = ""
        }
        return [kind, item.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Lógica

    private func submit(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        query = clean
        submitted = clean
        focused = false
        settings.rememberSearch(clean)
    }

    private func loadSuggestions() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != submitted else { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let found = await Catalog.suggestions(text)
        guard !Task.isCancelled else { return }
        suggestions = found.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
    }

    private func search() async {
        guard !submitted.isEmpty else { results = SearchResults(); return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let found = try await Catalog.search(submitted, filter: filter)
            guard !Task.isCancelled else { return }
            results = found
        } catch {
            guard !Task.isCancelled else { return }
            results = SearchResults()
            self.error = error.localizedDescription
        }
    }
}
