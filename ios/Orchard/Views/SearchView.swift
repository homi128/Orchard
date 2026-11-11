import SwiftUI

/// Búsqueda en vivo: cada letra que escribes actualiza los resultados, con carátulas.
struct SearchView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: AppUI

    @State private var query = ""
    @State private var filter: SearchFilter = .all
    @State private var results = SearchResults()
    /// Texto al que corresponden los resultados que se ven.
    @State private var shownQuery = ""
    @State private var suggestions: [String] = []
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !text.isEmpty {
                filterBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if text.isEmpty {
                        recents
                    } else {
                        if !suggestions.isEmpty { suggestionChips }
                        resultsBody
                    }
                }
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.22), value: shownQuery)
                .animation(.easeOut(duration: 0.22), value: filter)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Theme.base.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: text.isEmpty)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if ui.focusSearch { focused = true; ui.focusSearch = false } }
        .onChange(of: ui.focusSearch) { value in
            if value { focused = true; ui.focusSearch = false }
        }
        .task(id: "\(text)|\(filter.rawValue)") { await liveSearch() }
        .task(id: text) { await loadSuggestions() }
    }

    // MARK: Barra

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small).frame(width: 18)
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 18)
                }
                TextField("Canciones, artistas, álbumes", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { remember() }
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Borrar")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairline))
            if focused {
                Button("Cancelar") { focused = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { option in
                    Button { filter = option } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(filter == option ? Theme.accent : Theme.surface, in: Capsule())
                            .foregroundStyle(filter == option ? Color.black : Color.primary)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: Sin texto: recientes

    @ViewBuilder
    private var recents: some View {
        if settings.recentSearches.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.accent)
                Text("Escribe una letra y empiezan a aparecer canciones.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.horizontal, 40)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Búsquedas recientes").font(Theme.display(20, weight: .bold))
                    Spacer()
                    Button("Borrar") { settings.recentSearches = [] }.font(.subheadline)
                }
                .padding(.bottom, 6)
                ForEach(settings.recentSearches, id: \.self) { recent in
                    Button {
                        query = recent
                        focused = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text(recent)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Con texto: sugerencias y resultados

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { query = suggestion } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        if let error {
            ErrorBanner(message: error) { Task { await liveSearch() } }
        } else if results.isEmpty {
            if loading || shownQuery != text {
                loadingRows
            } else {
                Text("No encontré nada con \"\(text)\". Prueba con otro nombre.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                    .padding(.horizontal, 32)
            }
        } else if filter == .all {
            if let best = results.top.first ?? results.artists.first.flatMap({ artistMatches($0) ? $0 : nil }) {
                BestResultCard(item: best, songs: results.songs)
                    .padding(.horizontal)
                    .transition(.opacity)
            }
            if !results.songs.isEmpty {
                section("Canciones") { trackRows(Array(results.songs.prefix(6)), all: results.songs) }
            }
            if !results.artists.isEmpty {
                section("Artistas") { carousel(results.artists) }
            }
            if !results.albums.isEmpty {
                section("Álbumes") { carousel(results.albums) }
            }
            if !results.playlists.isEmpty {
                section("Playlists") { carousel(results.playlists) }
            }
            if !results.videos.isEmpty {
                section("Videos") { trackRows(Array(results.videos.prefix(5)), all: results.videos) }
            }
        } else {
            switch filter {
            case .songs: trackRows(unique(results.songs + results.top.compactMap(\.track)), all: results.songs)
            case .videos: trackRows(unique(results.videos + results.top.compactMap(\.track)), all: results.videos)
            case .albums: itemRows(results.albums + results.top.filter { $0.kind == .album })
            case .artists: itemRows(results.artists + results.top.filter { $0.kind == .artist })
            case .playlists: itemRows(results.playlists + results.top.filter { $0.kind == .playlist })
            case .all: EmptyView()
            }
        }
    }

    private func unique(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private func artistMatches(_ item: CatalogItem) -> Bool {
        item.title.lowercased().hasPrefix(text.lowercased())
    }

    private var loadingRows: some View {
        VStack(spacing: 14) {
            ForEach(0..<7, id: \.self) { _ in
                HStack(spacing: 12) {
                    Skeleton(width: 50, height: 50, corner: 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Skeleton(width: 190, height: 13, corner: 4)
                        Skeleton(width: 110, height: 11, corner: 4)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.display(20, weight: .bold))
                .padding(.horizontal)
            content()
        }
    }

    private func trackRows(_ tracks: [Track], all: [Track]) -> some View {
        VStack(spacing: 2) {
            ForEach(tracks) { track in
                Button {
                    remember()
                    let list = all.contains(track) ? all : tracks
                    player.play(list, startAt: list.firstIndex(of: track) ?? 0)
                } label: {
                    TrackRow(track: track, isCurrent: player.current?.id == track.id)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .trackActions(track, swipes: false)
                .transition(.opacity)
            }
        }
    }

    private func itemRows(_ items: [CatalogItem]) -> some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                ItemLink(item: item, siblings: items) {
                    HStack(spacing: 12) {
                        Artwork(url: item.thumbnail, fallback: item.track?.fallbackThumbnail, size: 56,
                                corner: item.kind == .artist ? 28 : 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                            Text(kindLabel(item)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if item.track == nil {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded { remember() })
            }
        }
    }

    private func carousel(_ items: [CatalogItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    ItemLink(item: item, siblings: items) { ItemCard(item: item, size: 128) }
                        .simultaneousGesture(TapGesture().onEnded { remember() })
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func kindLabel(_ item: CatalogItem) -> String {
        let kind: String
        switch item.kind {
        case .track: kind = "Canción"
        case .album: kind = "Álbum"
        case .playlist: kind = "Playlist"
        case .artist: kind = "Artista"
        case .other: kind = ""
        }
        return [kind, item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Lógica

    /// Guarda lo escrito como búsqueda reciente cuando eliges algo o presionas Buscar.
    private func remember() {
        if text.count >= 2 { settings.rememberSearch(text) }
    }

    private func liveSearch() async {
        let wanted = text
        guard !wanted.isEmpty else {
            results = SearchResults()
            shownQuery = ""
            error = nil
            loading = false
            return
        }
        // Esperar un instante: si sigues escribiendo, esta búsqueda se cancela.
        try? await Task.sleep(nanoseconds: 280_000_000)
        guard !Task.isCancelled else { return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let found = try await Catalog.search(wanted, filter: filter, quiet: true)
            guard !Task.isCancelled else { return }
            var clean = found
            clean.songs = unique(found.songs)
            clean.videos = unique(found.videos)
            results = clean
            shownQuery = wanted
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = SearchResults()
            shownQuery = wanted
            self.error = error.localizedDescription
        }
    }

    private func loadSuggestions() async {
        let wanted = text
        guard wanted.count >= 2 else { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let found = await Catalog.suggestions(wanted)
        guard !Task.isCancelled else { return }
        suggestions = found.filter { $0.caseInsensitiveCompare(wanted) != .orderedSame }
    }
}

/// El resultado más probable, en grande. Si es un artista, muestra también sus canciones.
struct BestResultCard: View {
    @EnvironmentObject private var player: Player
    let item: CatalogItem
    let songs: [Track]

    /// Canciones del resultado que pertenecen a este artista.
    private var artistSongs: [Track] {
        guard item.kind == .artist else { return [] }
        let name = item.title.lowercased()
        return Array(songs.filter { $0.artist.lowercased().contains(name) }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemLink(item: item, siblings: [item]) {
                HStack(spacing: 14) {
                    Artwork(url: item.thumbnail, fallback: item.track?.fallbackThumbnail, size: 88,
                            corner: item.kind == .artist ? 44 : 12)
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(Theme.display(22, weight: .bold))
                            .lineLimit(2)
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: item.track != nil ? "play.circle.fill" : "chevron.right.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent)
                }
                .contentShape(Rectangle())
            }
            if !artistSongs.isEmpty {
                Divider().overlay(Theme.hairline)
                ForEach(artistSongs) { track in
                    Button { player.play(artistSongs, startAt: artistSongs.firstIndex(of: track) ?? 0) } label: {
                        TrackRow(track: track, isCurrent: player.current?.id == track.id)
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                    .contextMenu { TrackMenuItems(track: track) }
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Theme.plum.opacity(0.75), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var label: String {
        switch item.kind {
        case .track: return ["Canción", item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        case .artist: return "Artista"
        case .album: return ["Álbum", item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        case .playlist: return ["Playlist", item.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        case .other: return item.subtitle
        }
    }
}
