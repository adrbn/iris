import AVFoundation
import NaturalLanguage
import SwiftUI
import Translation
import Vision

/// Universal reader for full-resolution Wi-Fi photos (BLE previews are too small to read):
/// Vision OCR → language guess → Apple Translation to French when needed → read aloud.
enum Reader {
    static func read(_ url: URL) async -> (text: String, french: String?) {
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(url: url).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
        guard !text.isEmpty, let lang = NLLanguageRecognizer.dominantLanguage(for: text), lang != .french else {
            return (text, nil)
        }
        let session = TranslationSession(installedSource: Locale.Language(identifier: lang.rawValue), target: Locale.Language(identifier: "fr"))
        return (text, try? await session.translate(text).targetText)
    }
}

struct ReaderSheet: View {
    let url: URL
    @State private var text = ""
    @State private var french: String?
    @State private var done = false
    @State private var voice = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !done { ProgressView("Lecture…") }
                    else if text.isEmpty { Text("Aucun texte trouvé.").foregroundStyle(.secondary) }
                    if let french { Text(french).font(.title3) }
                    if !text.isEmpty { Text(text).foregroundStyle(french == nil ? .primary : .secondary) }
                }
                .textSelection(.enabled).padding()
            }
            .navigationTitle("Lecteur")
            .toolbar {
                Button { speak() } label: { Image(systemName: "speaker.wave.2") }.disabled(text.isEmpty)
            }
        }
        .task {
            (text, french) = await Reader.read(url)
            done = true
            speak()
        }
        .onDisappear { voice.stopSpeaking(at: .immediate) }
    }

    private func speak() {
        let line = french ?? text
        guard !line.isEmpty else { return }
        voice.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: line)
        if french != nil { u.voice = AVSpeechSynthesisVoice.best() }
        voice.speak(u)
    }
}

extension AVSpeechSynthesisVoice {
    /// Best installed voice for a language: Premium > Enhanced > the compact default.
    /// Premium French voices are downloaded in Réglages › Accessibilité › Contenu énoncé › Voix.
    static func best(_ language: String = "fr-FR") -> AVSpeechSynthesisVoice? {
        speechVoices().filter { $0.language == language }.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}
