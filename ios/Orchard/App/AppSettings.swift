import Foundation

enum AudioQuality: String, CaseIterable, Identifiable {
    case high, normal, saver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: return "Alta"
        case .normal: return "Normal"
        case .saver: return "Ahorro de datos"
        }
    }
}

/// Preferencias de la app, guardadas en el iPhone.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var quality: AudioQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    /// Segundos de crossfade entre canciones (0 = sin crossfade).
    @Published var crossfade: Double { didSet { defaults.set(crossfade, forKey: "crossfade") } }
    @Published var autoplay: Bool { didSet { defaults.set(autoplay, forKey: "autoplay") } }
    @Published var sendHistory: Bool { didSet { defaults.set(sendHistory, forKey: "sendHistory") } }
    @Published var downloadOnCellular: Bool { didSet { defaults.set(downloadOnCellular, forKey: "downloadOnCellular") } }
    @Published var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: "recentSearches") } }

    private init() {
        quality = AudioQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high
        crossfade = defaults.object(forKey: "crossfade") as? Double ?? 0
        autoplay = defaults.object(forKey: "autoplay") as? Bool ?? true
        sendHistory = defaults.object(forKey: "sendHistory") as? Bool ?? true
        downloadOnCellular = defaults.object(forKey: "downloadOnCellular") as? Bool ?? true
        recentSearches = defaults.stringArray(forKey: "recentSearches") ?? []
    }

    func rememberSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recentSearches = Array(([text] + recentSearches.filter { $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(15))
    }
}
