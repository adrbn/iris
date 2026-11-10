import SwiftUI

/// Any OpenAI-compatible provider. Presets fill the address; the key is remembered per provider
/// (Keychain), and so is the last model picked there.
enum Providers {
    /// `model` is a sensible default used when switching to this provider with nothing saved yet, so
    /// a switch never carries the previous provider's (invalid) model over. Empty = pick one yourself.
    static let presets: [(name: String, url: String, model: String)] = [
        ("OpenRouter", "https://openrouter.ai/api/v1", ""),
        ("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
        ("Mistral", "https://api.mistral.ai/v1", "mistral-small-latest"),
        ("Groq", "https://api.groq.com/openai/v1", "meta-llama/llama-4-scout-17b-16e-instruct"),
        ("Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.1-flash-lite"),
        ("Ollama sur le Mac", Bundle.main.object(forInfoDictionaryKey: "IrisOllamaURL") as? String ?? "http://mon-mac.local:11434/v1", ""),
    ]

    /// Models that make images, video, speech or embeddings: they can't answer a question, and on
    /// Gemini's free tier their quota is 0, so every call is a 429 (gemini-2.5-flash-image, 08/11).
    static func cannotChat(_ id: String) -> Bool {
        ["-image", "imagen", "veo-", "tts", "embedding", "aqa", "lyria"].contains { id.localizedCaseInsensitiveContains($0) }
    }

    static func defaultModel(_ baseURL: String) -> String { presets.first { $0.url == baseURL }?.model ?? "" }

    /// The model to use at this provider: the one last picked there, else its default, else `fallback`.
    /// Requests go through this so a model left over from another provider is never sent.
    static func model(for baseURL: String, fallback: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: "model:" + Keychain.host(baseURL)), !saved.isEmpty, !cannotChat(saved) { return saved }
        let preset = defaultModel(baseURL)
        return preset.isEmpty ? fallback : preset
    }

    struct Model: Identifiable, Hashable { let id: String; let vision: Bool?; let free: Bool }

    /// GET /models. OpenRouter also says which models see images and which are free.
    static func models(baseURL: String, key: String) async throws -> [Model] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/models") else { throw AIClient.Failure.badURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIClient.Failure.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [Model] {
        struct List: Decodable {
            struct Item: Decodable {
                struct Arch: Decodable { let input_modalities: [String]? }
                struct Price: Decodable { let prompt: String?; let completion: String? }
                let id: String; let architecture: Arch?; let pricing: Price?
            }
            let data: [Item]
        }
        return try JSONDecoder().decode(List.self, from: data).data.map {
            Model(id: $0.id,
                  vision: $0.architecture?.input_modalities.map { $0.contains("image") },
                  free: $0.id.hasSuffix(":free") || ($0.pricing?.prompt == "0" && $0.pricing?.completion == "0"))
        }
        .sorted { ($0.vision == true ? 0 : 1, $0.free ? 0 : 1, $0.id) < ($1.vision == true ? 0 : 1, $1.free ? 0 : 1, $1.id) }
    }
}

enum ProviderCheck {
    enum State: Equatable { case unknown, testing, ok, failed(String) }

    /// OpenRouter's /models is public, so its key is checked on /key; elsewhere /models needs the key.
    static func test(baseURL: String, key: String) async -> State {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = base.contains("openrouter.ai") ? "/key" : "/models"
        guard let url = URL(string: base + path) else { return .failed("Adresse invalide.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .ok
            case 401, 403: return .failed(key.isEmpty ? "Ce fournisseur demande une clé." : "Clé refusée par le fournisseur.")
            case let code: return .failed("Réponse \(code) : \(String(decoding: data.prefix(120), as: UTF8.self))")
            }
        } catch {
            return .failed("Injoignable : \(error.localizedDescription)")
        }
    }
}

/// Carte « Fournisseur IA » de la feuille Réglages. Chaque fournisseur garde sa clé (Keychain) et
/// son modèle ; la clé est enregistrée à la frappe et testée en direct.
struct ProviderCard: View {
    @Binding var baseURL: String
    @Binding var model: String
    @State private var key = ""
    @State private var check = ProviderCheck.State.unknown
    @State private var testedIn = 0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Card {
            row("Fournisseur") {
                Menu {
                    Picker("Fournisseur", selection: preset) {
                        ForEach(Providers.presets, id: \.url) { Text($0.name).tag($0.url) }
                        Text("Autre (adresse ci-dessous)").tag("")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Providers.presets.first { $0.url == baseURL }?.name ?? "Autre")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Theme.ink)
                }
            }
            row("Adresse") {
                TextField("https://…", text: $baseURL).font(Theme.mono(.footnote)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
            NavigationLink { ModelList(baseURL: baseURL, key: key, model: $model) } label: {
                row("Modèle") {
                    Text(model.isEmpty ? "choisir" : model).font(Theme.mono(.footnote)).foregroundStyle(Theme.ink).lineLimit(1)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Clé API").foregroundStyle(Theme.ink)
                    SecureField("vide pour un modèle local", text: $key).font(Theme.mono(.footnote))
                        .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    status
                }
                switch check {
                case .ok: Meta("Clé valide · testée en \(testedIn) ms")
                case .failed(let why): Text(why).font(.footnote).foregroundStyle(.red)
                case .testing: Meta("Test…")
                case .unknown: EmptyView()
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .onAppear { key = Keychain.read(for: baseURL); model = Providers.model(for: baseURL, fallback: model) }
        .onChange(of: baseURL) { old, new in
            UserDefaults.standard.set(model, forKey: "model:" + Keychain.host(old))
            key = Keychain.read(for: new)
            // Use the model last picked at the new provider; otherwise its default, never the old one.
            model = Providers.model(for: new, fallback: "")
        }
        .onChange(of: key) { Keychain.save(key, for: baseURL) }
        .task(id: "\(baseURL)|\(key)") {
            check = .unknown
            guard !key.isEmpty || baseURL.hasPrefix("http:") else { return }
            try? await Task.sleep(for: .milliseconds(600)) // laisse finir la frappe
            guard !Task.isCancelled else { return }
            check = .testing
            let start = Date()
            let result = await ProviderCheck.test(baseURL: baseURL, key: key)
            guard !Task.isCancelled else { return }
            testedIn = Int(Date().timeIntervalSince(start) * 1000)
            check = result
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            value()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1).padding(.leading, 18) }
    }

    private var preset: Binding<String> {
        Binding(get: { Providers.presets.first { $0.url == baseURL }?.url ?? "" },
                set: { if !$0.isEmpty { baseURL = $0 } })
    }

    @ViewBuilder private var status: some View {
        switch check {
        case .ok:
            Image(systemName: "checkmark").font(.caption.weight(.bold))
                .foregroundStyle(scheme == .dark ? Color.black : Theme.accent)
                .frame(width: 24, height: 24).background(scheme == .dark ? Theme.accent : Theme.ink, in: Circle())
                .accessibilityLabel("Clé valide")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Clé refusée")
        case .testing: ProgressView()
        case .unknown: EmptyView()
        }
    }
}

struct ModelList: View {
    let baseURL: String
    let key: String
    @Binding var model: String
    @Environment(\.dismiss) private var dismiss
    @State private var models: [Providers.Model] = []
    @State private var error = ""
    @State private var query = ""
    @State private var visionOnly = true

    var body: some View {
        List {
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if models.contains(where: { $0.vision != nil }) { Toggle("Seulement ceux qui voient les images", isOn: $visionOnly) }
            ForEach(shown) { m in
                Button {
                    model = m.id
                    UserDefaults.standard.set(m.id, forKey: "model:" + Keychain.host(baseURL))
                    dismiss()
                } label: {
                    HStack {
                        Text(m.id).foregroundStyle(.primary)
                        Spacer()
                        if m.free { Tag(text: "gratuit") }
                        if m.vision == true { Tag(text: "voit les images") }
                        if m.id == model { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .overlay { if models.isEmpty && error.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "gemma, free, gpt…")
        .navigationTitle("Modèle")
        .task {
            do { models = try await Providers.models(baseURL: baseURL, key: key) }
            catch { self.error = "Liste indisponible : \(error.localizedDescription). Tu peux taper le nom à la main dans la recherche." }
        }
        .toolbar {
            if !query.isEmpty, !models.contains(where: { $0.id == query }) {
                Button("Utiliser « \(query) »") {
                    model = query
                    UserDefaults.standard.set(query, forKey: "model:" + Keychain.host(baseURL))
                    dismiss()
                }
            }
        }
    }

    private var shown: [Providers.Model] {
        models.filter { !Providers.cannotChat($0.id) && (!visionOnly || $0.vision != false) && (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)) }
    }
}

/// Étiquette mono 9.5 pt sur capsule, pour la liste des modèles.
private struct Tag: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9.5, design: .monospaced)).tracking(0.6)
            .foregroundStyle(Theme.muted).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.track, in: Capsule())
    }
}
