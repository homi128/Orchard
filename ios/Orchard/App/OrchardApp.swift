import SwiftUI

@main
struct OrchardApp: App {
    @StateObject private var sessions = SessionStore.shared
    @StateObject private var player = Player.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var downloads = DownloadStore.shared
    @StateObject private var ui = AppUI()
    @StateObject private var tint = ArtworkTint.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessions)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(ui)
                .environmentObject(tint)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

enum Tab: Hashable { case home, search, library }

/// Destinos de navegación compartidos por todas las pestañas.
enum Route: Hashable {
    case item(CatalogItem)
    case liked
    case downloads
    case settings
}

/// Estado de la interfaz que comparten varias pantallas.
@MainActor
final class AppUI: ObservableObject {
    @Published var tab: Tab = .home
    @Published var focusSearch = false
    @Published var addToPlaylist: Track?
    @Published var toast: String?

    func openSearch() {
        tab = .search
        focusSearch = true
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == message { toast = nil }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var ui: AppUI
    @EnvironmentObject private var downloads: DownloadStore
    @State private var showNowPlaying = false

    var body: some View {
        TabView(selection: $ui.tab) {
            NavigationStack { HomeView().withRoutes() }
                .withMiniPlayer($showNowPlaying)
                .tabItem { Label("Inicio", systemImage: "house.fill") }
                .tag(Tab.home)
            NavigationStack { SearchView().withRoutes() }
                .withMiniPlayer($showNowPlaying)
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            NavigationStack { LibraryView().withRoutes() }
                .withMiniPlayer($showNowPlaying)
                .tabItem { Label("Biblioteca", systemImage: "music.note.list") }
                .tag(Tab.library)
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $ui.addToPlaylist) { track in
            AddToPlaylistSheet(track: track)
                .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .top) {
            if let message = ui.toast ?? downloads.lastError {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { ui.toast = nil; downloads.lastError = nil }
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if downloads.lastError == message { downloads.lastError = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: ui.toast)
        .task(id: player.current?.id) { ArtworkTint.shared.update(for: player.current) }
    }
}

extension View {
    func withMiniPlayer(_ showNowPlaying: Binding<Bool>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(showNowPlaying: showNowPlaying)
        }
    }

    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .item(let item):
                if item.kind == .artist { ArtistView(item: item) } else { CollectionView(item: item) }
            case .liked:
                CollectionView(item: nil)
            case .downloads:
                DownloadsView()
            case .settings:
                SettingsView()
            }
        }
    }
}
