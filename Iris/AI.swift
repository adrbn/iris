import Foundation
import FoundationModels
import Security
import UIKit

/// Picks who answers: Apple's on-device model (free, nothing leaves the phone) when asked and
/// available, otherwise the OpenAI-compatible service from the settings.
enum Brain {
    static var appleStatus: String {
        if #available(iOS 27, *), AppleBrain.ready { return "Prête, elle voit l'image directement." }
        switch SystemLanguageModel.default.availability {
        case .available: return "Prête. Avant iOS 27 elle ne voit pas l'image : l'iPhone y reconnaît objets et texte, puis elle répond à partir de ça."
        case .unavailable(let reason): return "Indisponible : \(reason)."
        }
    }

    private static var appleText: Bool { SystemLanguageModel.default.availability == .available }

    static func answer(question: String?, jpeg: Data, apple: Bool, client: AIClient) async throws -> String {
        if apple, #available(iOS 27, *), AppleBrain.ready {
            return try await AppleBrain.answer(instructions: client.prompt, question: question, jpeg: jpeg)
        }
        if apple, appleText {
            // ponytail: Vision labels + OCR stand in for sight until iOS 27; weak on scenes and landmarks.
            let (labels, text) = Memory.tags(jpeg)
            let q = question ?? "Que vois-je ?"
            // Nothing recognized: answer the question as is, instead of "sans objet ni texte reconnu" (08/11).
            guard !labels.isEmpty || !text.isEmpty else { return try await respond("Tu réponds en français, brièvement.", q) }
            let seen = "Ce que la caméra des lunettes voit (reconnaissance automatique, peut se tromper). Objets : \(labels.isEmpty ? "aucun reconnu" : labels.joined(separator: ", ")). Texte lu : \(text.isEmpty ? "aucun" : text). Sers-t'en seulement si la question en a besoin."
            return try await respond(client.prompt, seen + "\n\nQuestion : " + q)
        }
        do { return try await client.describe(jpeg: jpeg, question: question) } catch {
            guard appleText else { throw error }
            await fallback(error, client)
            return try await answer(question: question, jpeg: jpeg, apple: true, client: client)
        }
    }

    /// Text only (journal…): Apple's model when allowed and present, otherwise the service.
    static func text(_ prompt: String, apple: Bool, client: AIClient) async throws -> String {
        if apple, appleText { return try await respond("Tu réponds en français.", prompt) }
        do { return try await client.complete([["type": "text", "text": prompt]]) } catch {
            guard appleText else { throw error }
            await fallback(error, client)
            return try await respond("Tu réponds en français.", prompt)
        }
    }

    /// The service failed (timeout, quota, unknown model): Apple's model answers instead of silence.
    /// Logs the service's real model ids once, to pick one that exists.
    private static var listed = false
    private static func fallback(_ error: Error, _ client: AIClient) async {
        Log.line("ia: service en échec (\(error.localizedDescription)), l'IA d'Apple répond")
        guard !listed else { return }
        listed = true
        let ids = (try? await Providers.models(baseURL: client.baseURL, key: client.apiKey))?.map(\.id) ?? []
        Log.line("ia: modèles du service : \(ids.filter { $0.contains("flash") || $0.contains("lite") }.joined(separator: ", "))")
    }

    private static func respond(_ instructions: String, _ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@available(iOS 27, *)
enum AppleBrain {
    static var ready: Bool {
        let model = SystemLanguageModel.default
        return model.availability == .available && model.capabilities.contains(.vision)
    }

    static var status: String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return model.capabilities.contains(.vision) ? "Prête, sur l'iPhone." : "Disponible, mais sans la vision sur cet iPhone."
        case .unavailable(let reason): return "Indisponible : \(reason)"
        }
    }

    static func answer(instructions: String, question: String?, jpeg: Data) async throws -> String {
        guard let image = UIImage(data: jpeg)?.cgImage else { throw AIClient.Failure.empty }
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond {
            question ?? "Que vois-je ?"
            Attachment(image)
        }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Any OpenAI-compatible endpoint: OpenAI, OpenRouter, Groq, Mistral, or a local
/// Ollama / LM Studio on the Mac (e.g. http://192.168.1.x:11434/v1). The app talks to
/// nothing else: no vendor cloud, no telemetry.
struct AIClient {
    var baseURL: String
    var model: String
    var apiKey: String
    var prompt: String

    enum Failure: LocalizedError {
        case badURL, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .badURL: "Adresse de l'IA invalide (Réglages)."
            case .http(429, let body) where body.localizedCaseInsensitiveContains("quota"):
                "Quota épuisé pour ce modèle (429). Choisis un autre modèle dans Réglages."
            case .http(429, let body): "Fournisseur saturé (429) : \(body.prefix(140)). Réessaie dans un instant ou change de modèle/fournisseur."
            case .http(401, _), .http(403, _): "Clé API refusée (Réglages)."
            case .http(let code, let body): "L'IA a répondu \(code) : \(body.prefix(200))"
            case .empty: "Réponse vide."
            }
        }
    }

    func describe(jpeg: Data, question: String? = nil) async throws -> String {
        try await complete([
            ["type": "text", "text": prompt + (question.map { "\n\nQuestion : \($0)" } ?? "")],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
        ])
    }

    func complete(_ content: [[String: Any]], maxTokens: Int = 600) async throws -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw Failure.badURL
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
        ]
        // Gemini 3 thinks at length by default: the guide (photo + Wikipedia) ran past 60 s on 08/11.
        // A spoken answer doesn't need it; low also keeps the thinking from eating max_tokens.
        if url.host?.contains("generativelanguage") == true { body["reasoning_effort"] = "low" }
        let started = Date()
        defer { Log.line("ia: \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code, String(decoding: data, as: UTF8.self)) }

        struct Reply: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
            let choices: [Choice]
        }
        let text = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content ?? ""
        guard !text.isEmpty else { throw Failure.empty }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// API keys live in the Keychain, never in UserDefaults: one per provider (keyed by host), so
/// switching OpenRouter → OpenAI → OpenRouter brings the OpenRouter key back.
enum Keychain {
    private static let legacy = "ai-api-key"

    static func host(_ baseURL: String) -> String {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
    }

    static func read(for baseURL: String) -> String {
        let account = "\(legacy):\(host(baseURL))"
        if let key = get(account) { return key }
        // Before per-provider keys there was a single one: it belongs to the provider set at the time.
        guard let old = get(legacy) else { return "" }
        set(old, account); set("", legacy)
        return old
    }

    static func save(_ value: String, for baseURL: String) { set(value, "\(legacy):\(host(baseURL))") }

    private static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func set(_ value: String, _ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
