import AVFoundation
import Speech
import SwiftUI
import Translation

/// Conversation translator, all on the phone: iPhone mic → Apple speech recognition →
/// Apple Translation (offline languages) → their words spoken in French in your ear,
/// your words shown big on screen in their language.
@MainActor
final class Translator: ObservableObject {
    enum Side { case them, me }
    @Published private(set) var listening: Side?
    @Published private(set) var heard = ""
    @Published private(set) var translated = ""
    @Published private(set) var error = ""
    @AppStorage("theirLanguage") var theirs = "en"

    static let languages = ["en": "Anglais", "it": "Italien", "es": "Espagnol", "de": "Allemand", "pt": "Portugais"]

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let voice = AVSpeechSynthesizer()

    @Published private(set) var detecting = false

    /// Lingua's method (claudecode_repos/shazam_lingua): record a few seconds, replay the clip through
    /// each candidate's on-device model ONE AT A TIME (the local engine serves a single request), and
    /// keep the language whose transcript is both confident and covers the clip.
    func detect() {
        guard listening == nil, !detecting else { return }
        detecting = true; error = ""; heard = "Parle-lui, j'écoute 4 s…"; translated = ""; lastSide = nil
        Task {
            defer { detecting = false }
            do {
                let clip = try await record(seconds: 4)
                var best: (lang: String, score: Double, text: String)?
                for lang in Self.languages.keys.sorted() {
                    guard let r = SFSpeechRecognizer(locale: Locale(identifier: Self.region(lang))), r.supportsOnDeviceRecognition else { continue }
                    let (score, text) = await Self.score(clip, r)
                    Log.line("langue \(lang) \(String(format: "%.2f", score)) « \(text.prefix(40)) »")
                    if score > (best?.score ?? 0.25) { best = (lang, score, text) }
                }
                if let best { theirs = best.lang; heard = "\(Self.languages[best.lang] ?? best.lang) : « \(best.text) »" }
                else { heard = ""; error = "Langue pas reconnue (trop calme, ou pas parmi les 5)." }
            } catch {
                heard = ""; self.error = error.localizedDescription
            }
        }
    }

    private func record(seconds: Double) async throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appending(path: "langue.caf")
        try? FileManager.default.removeItem(at: url)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in try? file.write(from: buffer) }
        engine.prepare()
        try engine.start()
        try await Task.sleep(for: .seconds(seconds))
        engine.stop()
        input.removeTap(onBus: 0)
        return url
    }

    /// Duration-weighted confidence × share of the clip with words (Lingua's LanguageEngine).
    static func score(_ clip: URL, _ r: SFSpeechRecognizer) async -> (Double, String) {
        let request = SFSpeechURLRecognitionRequest(url: clip)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let t: SFTranscription? = await withCheckedContinuation { done in
            var resumed = false
            r.recognitionTask(with: request) { result, err in
                guard !resumed, result?.isFinal == true || err != nil else { return }
                resumed = true
                done.resume(returning: result?.bestTranscription)
            }
        }
        guard let t, !t.segments.isEmpty else { return (0, "") }
        let weight = t.segments.reduce(0.0) { $0 + max($1.duration, 0.01) }
        let conf = t.segments.reduce(0.0) { $0 + Double($1.confidence) * max($1.duration, 0.01) } / weight
        let spoken = t.segments.reduce(0.0) { $0 + $1.duration }
        let coverage = spoken > 0 ? min(1, spoken / 4) : min(1, Double(t.segments.count) / 12)
        return (conf * coverage, t.formattedString)
    }

    func toggle(_ side: Side) {
        if listening != nil { finish(); return }
        start(side)
    }

    private func locale(_ side: Side) -> String { side == .me ? "fr-FR" : Self.region(theirs) }

    private static func region(_ lang: String) -> String {
        ["en": "en-US", "it": "it-IT", "es": "es-ES", "de": "de-DE", "pt": "pt-PT"][lang] ?? lang
    }

    private func start(_ side: Side) {
        error = ""; heard = ""; translated = ""
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale(side))), recognizer.isAvailable else {
            error = "Reconnaissance vocale indisponible pour cette langue."; return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            self.request = request
            listening = side
            task = recognizer.recognitionTask(with: request) { [weak self] result, err in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true || err != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.heard = text }
                    if final { self.finish() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            finish()
        }
    }

    private var lastSide: Side?

    private func finish() {
        guard let side = listening else { return }
        listening = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task = nil
        lastSide = side
        translate(heard, side: side)
    }

    private func translate(_ text: String, side: Side) {
        guard !text.isEmpty else { return }
        let from = Locale.Language(identifier: side == .me ? "fr" : theirs)
        let to = Locale.Language(identifier: side == .me ? theirs : "fr")
        Task {
            do {
                let session = TranslationSession(installedSource: from, target: to)
                translated = try await session.translate(text).targetText
                if side == .them { say(translated, "fr-FR") }
            } catch {
                self.error = "Traduction impossible : télécharge le français et l'\(Self.languages[theirs] ?? theirs) dans Réglages › Apps › Traduire › Langues. (\(error.localizedDescription))"
            }
        }
    }

    /// Changer de langue après une phrase « Moi » (français fixe) la re-traduit vers la nouvelle langue.
    /// Côté « Lui/elle » la cible est toujours le français, rien à refaire.
    func retranslate() {
        guard listening == nil, lastSide == .me, !heard.isEmpty else { return }
        translate(heard, side: .me)
    }

    private func say(_ text: String, _ language: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice.best(language)
        voice.speak(u)
    }
}

struct TranslatorView: View {
    @StateObject private var t = Translator()

    var body: some View {
        VStack(spacing: 16) {
            Picker("Sa langue", selection: $t.theirs) {
                ForEach(Translator.languages.sorted(by: { $0.value < $1.value }), id: \.key) { Text($0.value).tag($0.key) }
            }
            .pickerStyle(.segmented)
            .onChange(of: t.theirs) { t.retranslate() }
            Button(t.detecting ? "J'écoute…" : "Quelle langue ? (détecter)") { t.detect() }
                .disabled(t.detecting || t.listening != nil)

            ScrollView {
                Text(t.translated.isEmpty ? " " : t.translated)
                    .font(.system(size: 34, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 160, maxHeight: 320)
            Text(t.heard).foregroundStyle(.secondary)
            if !t.error.isEmpty { Text(t.error).font(.footnote).foregroundStyle(.red) }
            Spacer()
            HStack(spacing: 12) {
                button("Lui / elle", .them, "person.wave.2")
                button("Moi", .me, "person.fill")
            }
            Text("« Lui / elle » : sa phrase est dite en français dans tes lunettes. « Moi » : ta phrase s'affiche en grand dans sa langue, tourne l'écran vers lui. Touche une 2e fois pour finir.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Traducteur")
    }

    private func button(_ label: String, _ side: Translator.Side, _ icon: String) -> some View {
        Button { t.toggle(side) } label: {
            Label(t.listening == side ? "Terminer" : label, systemImage: t.listening == side ? "stop.circle.fill" : icon)
                .frame(maxWidth: .infinity, minHeight: 56).font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .tint(t.listening == side ? .red : .accentColor)
        .disabled(t.listening != nil && t.listening != side)
    }
}
