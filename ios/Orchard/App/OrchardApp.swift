import SwiftUI

@main
struct OrchardApp: App {
    @StateObject private var sessions = SessionStore.shared
    @StateObject private var player = Player.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessions)
                .environmentObject(player)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.71, green: 0.63, blue: 1.0)
}

struct RootView: View {
    @EnvironmentObject private var player: Player
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .withMiniPlayer($showNowPlaying)
                .tabItem { Label("Inicio", systemImage: "house.fill") }
            NavigationStack { SearchView() }
                .withMiniPlayer($showNowPlaying)
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .withMiniPlayer($showNowPlaying)
                .tabItem { Label("Biblioteca", systemImage: "music.note.list") }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func withMiniPlayer(_ showNowPlaying: Binding<Bool>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(showNowPlaying: showNowPlaying)
        }
    }
}
