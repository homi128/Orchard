import SwiftUI
import WebKit

/// Inicio de sesión de YouTube Music con la página real de Google,
/// igual que NativeLoginScreen en Android: al llegar a music.youtube.com con
/// sesión iniciada, se leen las cookies y los datos de la página.
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Inicia sesión con tu cuenta de Google."

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                LoginWebView { session in
                    SessionStore.shared.save(session)
                    dismiss()
                } onStatus: { text in
                    status = text
                }
            }
            .navigationTitle("YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let onSession: (YouTubeSession) -> Void
    let onStatus: (String) -> Void

    static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com")!
    /// Safari de iPhone: Google acepta el inicio de sesión desde este navegador.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    @MainActor
    static func clearWebsiteData() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let google = records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: google) {}
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: Self.loginURL))
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        weak var webView: WKWebView?
        private var finished = false
        private var probing = false

        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await probe(webView) }
        }

        private func isYouTube(_ url: URL?) -> Bool {
            guard let host = url?.host?.lowercased() else { return false }
            return host == "youtube.com" || host.hasSuffix(".youtube.com")
        }

        private func probe(_ webView: WKWebView) async {
            guard !finished, !probing else { return }
            guard isYouTube(webView.url),
                  webView.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "signin" else { return }
            probing = true
            parent.onStatus("Revisando la sesión...")
            let raw = try? await webView.evaluateJavaScript(Self.configScript)
            let config = (raw as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let cookie = Self.mergedCookie(cookies)
            probing = false
            guard YouTubeSession.isSignedIn(cookie: cookie) else {
                parent.onStatus("Inicia sesión con tu cuenta de Google.")
                // La página puede terminar de iniciar sesión sin una nueva carga.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let current = self.webView { await probe(current) }
                return
            }
            finished = true
            let dataSyncId = Self.delegatedId(config["dataSyncId"] as? String, config["delegatedSessionId"] as? String)
            let accountIndex = Int("\(config["accountIndex"] ?? "0")") ?? 0
            parent.onSession(YouTubeSession(
                cookie: cookie,
                visitorData: (config["visitorData"] as? String) ?? "",
                dataSyncId: dataSyncId,
                accountIndex: max(0, accountIndex),
                avatarUrl: (config["avatarUrl"] as? String) ?? ""
            ))
        }

        /// Igual que mergedYouTubeCookie en Android: una cookie por nombre, prefiriendo
        /// las de music.youtube.com sobre las del dominio general.
        static func mergedCookie(_ cookies: [HTTPCookie]) -> String {
            let now = Date()
            let relevant = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (domain == "youtube.com" || domain.hasSuffix(".youtube.com"))
                    && (cookie.expiresDate.map { $0 > now } ?? true)
            }
            func rank(_ cookie: HTTPCookie) -> Int {
                let domain = cookie.domain.lowercased()
                if domain.contains("music.youtube.com") { return 0 }
                if domain.contains("www.youtube.com") { return 1 }
                return 2
            }
            var values: [(String, String)] = []
            var seen = Set<String>()
            for cookie in relevant.sorted(by: { rank($0) < rank($1) }) where seen.insert(cookie.name).inserted {
                values.append((cookie.name, cookie.value))
            }
            return values.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
        }

        /// YouTubeSessionAuth.delegatedId: la cuenta de marca usa el id delegado.
        /// DATASYNC_ID se lee "idDelegado||idUsuario"; una cuenta personal es "idUsuario||" y queda vacía.
        static func delegatedId(_ dataSyncId: String?, _ delegatedSessionId: String?) -> String {
            if let delegated = delegatedSessionId?.trimmingCharacters(in: .whitespaces), !delegated.isEmpty {
                return delegated
            }
            let decoded = (dataSyncId ?? "").trimmingCharacters(in: .whitespaces).removingPercentEncoding
                ?? (dataSyncId ?? "")
            guard let separator = decoded.range(of: "||"), separator.lowerBound > decoded.startIndex else { return "" }
            let rest = decoded[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "" : String(decoded[..<separator.lowerBound])
        }

        static let configScript = """
        (function() {
          try {
            var config = window.ytcfg;
            var get = config && typeof config.get === 'function' ? function(key) { return config.get(key); } : function() { return ''; };
            var legacy = window.yt && window.yt.config_ ? window.yt.config_ : {};
            var findScriptValue = function(key) {
              for (var i = 0; i < document.scripts.length; i++) {
                var text = document.scripts[i].textContent || '';
                var match = text.match(new RegExp('"' + key + '":"([^"]+)"'));
                if (match) return match[1];
              }
              return '';
            };
            var avatar = document.querySelector('#avatar-btn img[src], ytmusic-settings-button button img[src], ytmusic-nav-bar #avatar img[src]');
            var avatarUrl = avatar ? (avatar.currentSrc || avatar.src || '') : '';
            var accountIndex = get('SESSION_INDEX');
            if (accountIndex === '' || accountIndex == null) accountIndex = legacy.SESSION_INDEX;
            if (accountIndex === '' || accountIndex == null) accountIndex = findScriptValue('SESSION_INDEX');
            return JSON.stringify({
              visitorData: get('VISITOR_DATA') || legacy.VISITOR_DATA || findScriptValue('VISITOR_DATA') || '',
              delegatedSessionId: get('DELEGATED_SESSION_ID') || legacy.DELEGATED_SESSION_ID || findScriptValue('DELEGATED_SESSION_ID') || '',
              dataSyncId: get('DATASYNC_ID') || legacy.DATASYNC_ID || findScriptValue('DATASYNC_ID') || '',
              accountIndex: accountIndex == null ? '' : String(accountIndex),
              avatarUrl: /^data:/i.test(avatarUrl) ? '' : avatarUrl
            });
          } catch (error) {
            return JSON.stringify({ visitorData: '', delegatedSessionId: '', dataSyncId: '', accountIndex: '0' });
          }
        })();
        """
    }
}
