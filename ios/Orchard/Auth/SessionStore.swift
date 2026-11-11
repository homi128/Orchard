import Foundation
import Security

/// La sesión de YouTube Music que firma las peticiones del proveedor.
/// Mismos campos que YouTubeSession en Android.
struct YouTubeSession: Codable, Equatable {
    var cookie: String
    var visitorData: String
    var dataSyncId: String
    var accountIndex: Int
    var avatarUrl: String

    var providerJSON: [String: Any] {
        var json: [String: Any] = ["cookie": cookie]
        if !visitorData.isEmpty { json["visitorData"] = visitorData }
        if !dataSyncId.isEmpty { json["dataSyncId"] = dataSyncId }
        if accountIndex != 0 { json["accountIndex"] = accountIndex }
        return json
    }

    /// Cookies que indican una sesión iniciada (YouTubeSessionAuth.LOGIN_COOKIE_NAMES).
    static let loginCookieNames = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID", "APISID"]

    static func isSignedIn(cookie: String) -> Bool {
        cookie.split(separator: ";").contains { part in
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { return false }
            let name = pieces[0].trimmingCharacters(in: .whitespaces)
            return loginCookieNames.contains(name) && !pieces[1].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var session: YouTubeSession?

    private let service = "dev.orchard.ios.youtube-session"
    private let account = "default"

    private init() {
        session = load()
    }

    var isSignedIn: Bool { session != nil }

    func save(_ newSession: YouTubeSession) {
        guard let data = try? JSONEncoder().encode(newSession) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        session = newSession
    }

    func signOut() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        session = nil
        LoginWebView.clearWebsiteData()
    }

    private func load() -> YouTubeSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(YouTubeSession.self, from: data),
              YouTubeSession.isSignedIn(cookie: stored.cookie)
        else { return nil }
        return stored
    }
}
