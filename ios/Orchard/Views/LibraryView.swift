import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var downloads: DownloadStore
    @State private var sections: [String: [CatalogItem]] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var showNewPlaylist = false

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.liked) {
                    Label("Canciones que te gustan", systemImage: "heart.fill")
                }
                .disabled(!sessions.isSignedIn)
                NavigationLink(value: Route.downloads) {
                    HStack {
                        Label("Descargas", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        if !downloads.entries.isEmpty {
                            Text("\(downloads.entries.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !sessions.isSignedIn {
                SignInPrompt(message: "Inicia sesión en YouTube Music para ver tus playlists y reproducir canciones.")
                    .listRowBackground(Color.clear)
            } else {
                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                }
                if loading && sections.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                itemSection("Playlists", key: "playlists", systemImage: "music.note.list")
                itemSection("Álbumes", key: "albums", systemImage: "square.stack")
                itemSection("Artistas", key: "artists", systemImage: "music.mic")
            }
        }
        .navigationTitle("Biblioteca")
        .scrollContentBackground(.hidden)
        .background(Theme.base.ignoresSafeArea())
        .refreshable { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if sessions.isSignedIn {
                    Button { showNewPlaylist = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Nueva playlist")
                }
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Ajustes")
            }
        }
        .task(id: sessions.session?.cookie) {
            if sessions.isSignedIn { await load() } else { sections = [:] }
        }
        .alert("Nueva playlist", isPresented: $showNewPlaylist) {
            NewPlaylistAlert(track: nil) { Task { await load() } }
        }
    }

    @ViewBuilder
    private func itemSection(_ title: String, key: String, systemImage: String) -> some View {
        let items = sections[key] ?? []
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    ItemLink(item: item) {
                        HStack(spacing: 12) {
                            Artwork(url: item.thumbnail, size: 52, corner: item.kind == .artist ? 26 : 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            var found = try await Catalog.library()
            if (found["playlists"] ?? []).isEmpty, let playlists = try? await Catalog.playlists() {
                found["playlists"] = playlists
            }
            sections = found
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Campos de la alerta "Nueva playlist".
struct NewPlaylistAlert: View {
    @EnvironmentObject private var ui: AppUI
    let track: Track?
    var done: () -> Void = {}
    @State private var title = ""

    var body: some View {
        TextField("Nombre", text: $title)
        Button("Cancelar", role: .cancel) {}
        Button("Crear") {
            let name = title
            Task {
                do {
                    try await Catalog.createPlaylist(name, with: track)
                    ui.show(track == nil ? "Playlist creada" : "Agregada a \(name)")
                    done()
                } catch {
                    ui.show(error.localizedDescription)
                }
            }
        }
        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

/// Playlist, álbum o "Canciones que te gustan" (`item == nil`).
struct CollectionView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var ui: AppUI
    let item: CatalogItem?
    @State private var page: CollectionPage?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var error: String?

    private var tracks: [Track] { page?.tracks ?? [] }
    private var title: String { page?.title ?? item?.title ?? "Canciones que te gustan" }

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let error {
                ErrorBanner(message: error) { Task { await load() } }
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                    Button {
                        player.play(tracks, startAt: offset)
                    } label: {
                        TrackRow(track: track, isCurrent: player.current?.id == track.id,
                                 number: item?.kind == .album ? offset + 1 : nil)
                    }
                    .buttonStyle(.plain)
                    .trackActions(track)
                    .onAppear {
                        if offset >= tracks.count - 8 { Task { await loadMore() } }
                    }
                }
                if loadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            ForEach(page?.sections ?? []) { shelf in
                ShelfView(shelf: shelf)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.base.ignoresSafeArea())
        .overlay { if loading && tracks.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        player.addToQueue(tracks)
                        ui.show("\(tracks.count) canciones agregadas a la cola")
                    } label: { Label("Agregar todo a la cola", systemImage: "text.append") }
                    Button {
                        downloads.download(tracks)
                        ui.show("Descargando \(tracks.count) canciones")
                    } label: { Label("Descargar todo", systemImage: "arrow.down.circle") }
                    if let id = page?.playlistId ?? item?.browseId.map({ $0.hasPrefix("VL") ? String($0.dropFirst(2)) : $0 }),
                       item != nil, item?.kind != .artist {
                        Button {
                            Task {
                                do {
                                    try await Catalog.setSaved(id, saved: true)
                                    ui.show("Guardada en tu biblioteca")
                                } catch { ui.show(error.localizedDescription) }
                            }
                        } label: { Label("Guardar en la biblioteca", systemImage: "plus.circle") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(tracks.isEmpty)
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 14) {
            if let item {
                Artwork(url: page?.thumbnail ?? item.thumbnail, size: 220, corner: 18)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 200, height: 200)
                    .overlay(Image(systemName: "heart.fill").font(.system(size: 64)).foregroundStyle(.white))
            }
            Text(title)
                .font(Theme.display(26))
                .multilineTextAlignment(.center)
            let subtitle = page?.subtitle ?? item?.subtitle ?? ""
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button {
                    player.play(tracks)
                } label: { Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                Button {
                    player.play(tracks, startAt: Int.random(in: 0..<max(tracks.count, 1)), shuffled: true)
                } label: { Label("Aleatorio", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
        }
        .padding(.vertical, 8)
        .background(alignment: .top) {
            // La carátula, difuminada, ilumina la cabecera.
            Artwork(url: page?.thumbnail ?? item?.thumbnail, corner: 0)
                .frame(width: 420, height: 320)
                .blur(radius: 70)
                .opacity(0.5)
                .offset(y: -90)
                .allowsHitTesting(false)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result: CollectionPage
            if let item {
                result = try await Catalog.collection(item)
            } else {
                result = try await Catalog.likedSongs()
            }
            page = result
            error = result.tracks.isEmpty && result.sections.isEmpty ? "No encontré canciones aquí." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, let continuation = page?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let more = try await Catalog.more(continuation, startIndex: tracks.count)
            let known = Set(tracks.map(\.id))
            page?.tracks += more.tracks.filter { !known.contains($0.id) }
            page?.continuation = more.continuation
        } catch {
            page?.continuation = nil
        }
    }
}

struct ArtistView: View {
    @EnvironmentObject private var player: Player
    let item: CatalogItem
    @State private var page: CollectionPage?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Artwork(url: page?.thumbnail ?? item.thumbnail, size: 180, corner: 90)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                    Text(page?.title ?? item.title)
                        .font(Theme.display(34))
                        .multilineTextAlignment(.center)
                    if let subtitle = page?.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let tracks = page?.tracks, !tracks.isEmpty {
                        HStack(spacing: 12) {
                            Button { player.play(tracks) } label: {
                                Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                Task {
                                    if let first = tracks.first, let more = try? await Catalog.upNext(after: first) {
                                        player.play([first] + more)
                                    }
                                }
                            } label: {
                                Label("Radio", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity)

                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                }

                if let tracks = page?.tracks, !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Canciones populares").font(Theme.display(22, weight: .bold)).padding(.horizontal)
                        ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                            Button { player.play(tracks, startAt: offset) } label: {
                                TrackRow(track: track, isCurrent: player.current?.id == track.id)
                                    .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                            .trackActions(track, swipes: false)
                        }
                    }
                }

                ForEach(page?.sections ?? []) { shelf in
                    ShelfView(shelf: shelf)
                }
            }
            .padding(.vertical)
        }
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.base
                Artwork(url: page?.thumbnail ?? item.thumbnail, corner: 0)
                    .frame(height: 360)
                    .blur(radius: 80)
                    .opacity(0.45)
            }
            .ignoresSafeArea()
        }
        .overlay { if loading && page == nil { ProgressView() } }
        .navigationTitle(page?.title ?? item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            page = try await Catalog.collection(item)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddToPlaylistSheet: View {
    @EnvironmentObject private var ui: AppUI
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var targets: [PlaylistTarget] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TrackRow(track: track)
                }
                Section {
                    Button { showNew = true } label: { Label("Nueva playlist", systemImage: "plus") }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    ForEach(targets) { target in
                        Button {
                            Task {
                                do {
                                    try await Catalog.add(track, toPlaylist: target.id)
                                    ui.show("Agregada a \(target.title)")
                                    dismiss()
                                } catch { ui.show(error.localizedDescription) }
                            }
                        } label: {
                            HStack {
                                Text(target.title).foregroundStyle(.primary)
                                Spacer()
                                if target.containsTrack {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .disabled(target.containsTrack)
                    }
                }
            }
            .navigationTitle("Agregar a una playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
            .alert("Nueva playlist", isPresented: $showNew) {
                NewPlaylistAlert(track: track) { dismiss() }
            }
            .task {
                defer { loading = false }
                do { targets = try await Catalog.playlistTargets(for: track) } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var player: Player
    @State private var confirmDelete = false

    private var tracks: [Track] { downloads.entries.map(\.track) }

    var body: some View {
        List {
            if downloads.entries.isEmpty && downloads.progress.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 44)).foregroundStyle(Theme.accent)
                    Text("Aún no descargas canciones. Mantén presionada una canción y elige Descargar, o usa \"Descargar todo\" en una playlist.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    HStack(spacing: 12) {
                        Button { player.play(tracks) } label: {
                            Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { player.play(tracks, startAt: Int.random(in: 0..<max(tracks.count, 1)), shuffled: true) } label: {
                            Label("Aleatorio", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(tracks.isEmpty)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("\(downloads.entries.count) canciones · \(formatBytes(downloads.totalBytes))")
                }
                if !downloads.progress.isEmpty {
                    Section("Descargando") {
                        ForEach(downloads.progress.keys.sorted(), id: \.self) { id in
                            HStack {
                                ProgressView(value: downloads.progress[id] ?? 0)
                                Button { downloads.cancel(id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                        Button { player.play(tracks, startAt: offset) } label: {
                            TrackRow(track: track, isCurrent: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenuItems(track: track) }
                    }
                    .onDelete { offsets in
                        for offset in offsets { downloads.delete(tracks[offset].id) }
                    }
                }
            }
        }
        .navigationTitle("Descargas")
        .toolbar {
            if !downloads.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Borrar todo", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("¿Borrar todas las descargas?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Borrar \(downloads.entries.count) canciones", role: .destructive) { downloads.deleteAll() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var downloads: DownloadStore
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                Picker("Calidad de audio", selection: $settings.quality) {
                    ForEach(AudioQuality.allCases) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Crossfade")
                        Spacer()
                        Text(settings.crossfade == 0 ? "Desactivado" : "\(Int(settings.crossfade)) s")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.crossfade, in: 0...12, step: 1)
                }
                Toggle("Autoplay al terminar la cola", isOn: $settings.autoplay)
            } header: {
                Text("Reproducción")
            } footer: {
                Text("El crossfade mezcla el final de una canción con el inicio de la siguiente. Autoplay agrega canciones parecidas cuando la cola se acaba.")
            }

            Section {
                Toggle("Descargar con datos móviles", isOn: $settings.downloadOnCellular)
                LabeledContent("Espacio usado", value: formatBytes(downloads.totalBytes))
            } header: {
                Text("Descargas")
            }

            Section {
                Toggle("Guardar en el historial de YouTube", isOn: $settings.sendHistory)
            } footer: {
                Text("Lo que escuchas aparece en tu historial y mejora tus recomendaciones, igual que en la app oficial.")
            }

            Section("Cuenta") {
                if sessions.isSignedIn {
                    Button("Cerrar sesión de YouTube Music", role: .destructive) { confirmSignOut = true }
                } else {
                    SignInPrompt(message: "No has iniciado sesión.")
                }
            }

            Section {
                LabeledContent("Versión", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Link("Orchard en GitHub", destination: URL(string: "https://github.com/SFG5453/Orchard")!)
            } footer: {
                Text("Orchard para iPhone usa el mismo motor que Orchard para escritorio y Android. Software libre bajo AGPL-3.0.")
            }
        }
        .navigationTitle("Ajustes")
        .confirmationDialog("¿Cerrar la sesión de YouTube Music?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { sessions.signOut() }
        }
    }
}
