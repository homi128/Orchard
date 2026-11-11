import Foundation

/// Error que devuelve el proveedor de YouTube (mensaje ya legible).
struct ProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Llamadas al proveedor de YouTube compartido con escritorio y Android.
/// Los métodos y las formas de los datos son los de providers/youtube/src/runtime.
enum Provider {
    static func call(_ method: String, _ payload: [String: Any] = [:]) async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            OrchardEngine.shared().invoke(method, payload: json) { ok, result in
                guard ok else {
                    continuation.resume(throwing: ProviderError(message: result.isEmpty ? "YouTube no respondió." : result))
                    return
                }
                do {
                    let value = try JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: ProviderError(message: "Respuesta inesperada de YouTube."))
                }
            }
        }
    }

    static func object(_ method: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await call(method, payload)
        guard let dictionary = value as? [String: Any] else {
            throw ProviderError(message: "Respuesta inesperada de YouTube.")
        }
        return dictionary
    }

    static func array(_ method: String, _ payload: [String: Any] = [:]) async throws -> [Any] {
        let value = try await call(method, payload)
        if let list = value as? [Any] { return list }
        if let dictionary = value as? [String: Any] {
            for key in ["tracks", "items"] {
                if let list = dictionary[key] as? [Any] { return list }
            }
        }
        return []
    }
}
