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

    // Ecualizador
    @Published var eqEnabled: Bool { didSet { defaults.set(eqEnabled, forKey: "eqEnabled"); pushEqualizer() } }
    /// true = modo completo de 10 bandas; false = graves, medios y agudos.
    @Published var eqFull: Bool { didSet { defaults.set(eqFull, forKey: "eqFull"); pushEqualizer() } }
    /// Graves, medios, agudos (dB).
    @Published var eqSimple: [Double] { didSet { defaults.set(eqSimple, forKey: "eqSimple"); pushEqualizer() } }
    /// Las 10 bandas del modo completo (dB).
    @Published var eqBands: [Double] { didSet { defaults.set(eqBands, forKey: "eqBands"); pushEqualizer() } }

    /// Las ganancias que se están aplicando al sonido, según el modo.
    var eqEffective: [Double] {
        eqFull ? eqBands : Equalizer.bands(bass: eqSimple[0], mid: eqSimple[1], treble: eqSimple[2])
    }

    private func pushEqualizer() {
        Equalizer.apply(enabled: eqEnabled, gains: eqEffective)
    }

    private init() {
        quality = AudioQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high
        crossfade = defaults.object(forKey: "crossfade") as? Double ?? 0
        autoplay = defaults.object(forKey: "autoplay") as? Bool ?? true
        sendHistory = defaults.object(forKey: "sendHistory") as? Bool ?? true
        downloadOnCellular = defaults.object(forKey: "downloadOnCellular") as? Bool ?? true
        recentSearches = defaults.stringArray(forKey: "recentSearches") ?? []
        eqEnabled = defaults.bool(forKey: "eqEnabled")
        eqFull = defaults.bool(forKey: "eqFull")
        let simple = defaults.array(forKey: "eqSimple") as? [Double] ?? []
        eqSimple = simple.count == 3 ? simple : [0, 0, 0]
        let bands = defaults.array(forKey: "eqBands") as? [Double] ?? []
        eqBands = bands.count == 10 ? bands : [Double](repeating: 0, count: 10)
        pushEqualizer()
    }

    func rememberSearch(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recentSearches = Array(([text] + recentSearches.filter { $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(15))
    }
}
