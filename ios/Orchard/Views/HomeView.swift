import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var player: Player
    @State private var shelves: [Shelf] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SearchLauncher()
                    .padding(.horizontal)
                if !sessions.isSignedIn {
                    SignInPrompt().padding(.top, 40)
                } else if loading && shelves.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                } else if let error, shelves.isEmpty {
                    ErrorBanner(message: error) { Task { await load() } }
                } else {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(shelves) { shelf in
                            ShelfView(shelf: shelf)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable { await load() }
        .navigationTitle("Inicio")
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
