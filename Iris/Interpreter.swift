import AVFoundation
import Speech
import SwiftUI
import Translation

/// Simultaneous interpretation: someone talks on (a guide, a talk, a film); every pause closes a
/// sentence that is translated to French on the phone (Apple Translation) and said in your ear while
/// the next one is already being heard. Voice-chat mode cancels the echo of our own voice.
@MainActor
final class Interpreter: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let heard: String; var french: String }

    @Published private(set) var running = false
    @Published private(set) var current = ""
    @Published private(set) var lines: [Line] = []
    @Published private(set) var error = ""
    @AppStorage("interpLanguage") var source = "en"
    @AppStorage("interpSpeak") var speak = true

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pause: Timer?
    private let voice = AVSpeechSynthesizer()
    private var translator: TranslationSession?

    func toggle() { running ? stop() : start() }

    private func start() {
        error = ""
        let locale = ["en": "en-US", "it": "it-IT", "es": "es-ES", "de": "de-DE", "pt": "pt-PT"][source] ?? source
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            error = "Reconnaissance vocale indisponible pour cette langue."; return
        }
        self.recognizer = recognizer
        translator = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: "fr"))
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                Task { @MainActor in self?.request?.append(buffer) }
            }
            engine.prepare()
            try engine.start()
            running = true
            segment()
            Log.line("interprète: \(source) → fr")
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    private func stop() {
        running = false
        pause?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        close()
    }

    /// One recognition request per sentence: a pause ends it, it's translated, a new one starts at once.
    private func segment() {
        guard running, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        current = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal == true || err != nil
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if !text.isEmpty { self.current = text; self.waitForPause() }
                if final { self.close(); self.segment() }
            }
        }
    }

    private func waitForPause() {
        pause?.invalidate()
        pause = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            Task { @MainActor in guard let self, self.running else { return }; self.close(); self.segment() }
        }
    }

    /// Ends the current request and sends what it heard to translation.
    private func close() {
        pause?.invalidate()
        let text = current.trimmingCharacters(in: .whitespaces)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        current = ""
        guard !text.isEmpty else { return }
        let line = Line(heard: text, french: "…")
        lines.append(line)
        Task {
            do {
                guard let translator else { return }
                let french = try await translator.translate(text).targetText
                if let i = lines.firstIndex(where: { $0.id == line.id }) { lines[i].french = french }
                if speak { say(french) }
            } catch {
                self.error = "Traduction impossible : télécharge le français et l'\(Translator.languages[source] ?? source) dans Réglages › Apps › Traduire › Langues."
                if let i = lines.firstIndex(where: { $0.id == line.id }) { lines[i].french = "" }
            }
        }
    }

    private func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice.best("fr-FR")
        u.rate = 0.55   // a bit fast: the speaker doesn't wait for us
        voice.speak(u)
    }

    func clear() { lines = [] }
}

struct InterpreterView: View {
    @StateObject private var i = Interpreter()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Picker("Langue écoutée", selection: $i.source) {
                    ForEach(Translator.languages.sorted(by: { $0.value < $1.value }), id: \.key) { Text($0.value).tag($0.key) }
                }
                .pickerStyle(.segmented)
                .disabled(i.running)
                Toggle("Dire la traduction à l'oreille", isOn: $i.speak).tint(Theme.accent).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, Theme.margin).padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(i.lines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.french).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text(line.heard).font(.footnote).foregroundStyle(Theme.muted)
                            }
                            .id(line.id)
                        }
                        if !i.current.isEmpty {
                            Text(i.current).font(.callout).foregroundStyle(Theme.muted).italic().id("live")
                        }
                        if i.lines.isEmpty && i.current.isEmpty {
                            Text(i.running ? "J'écoute…" : "Pose l'iPhone près de la personne qui parle, puis touche le bouton. Chaque pause déclenche la traduction.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                        if !i.error.isEmpty { Text(i.error).font(.footnote).foregroundStyle(.red) }
                    }
                    .padding(Theme.margin)
                }
                .onChange(of: i.lines.count) { withAnimation { proxy.scrollTo(i.lines.last?.id, anchor: .bottom) } }
                .onChange(of: i.current) { proxy.scrollTo("live", anchor: .bottom) }
            }

            Button(action: i.toggle) {
                Label(i.running ? "Arrêter" : "Interpréter", systemImage: i.running ? "stop.fill" : "waveform")
                    .font(.headline).foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(i.running ? Color.red : Theme.accent, in: Capsule())
            }
            .buttonStyle(Pressable())
            .padding(.horizontal, Theme.margin).padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Interprétation simultanée")
        .toolbar { if !i.lines.isEmpty && !i.running { Button("Effacer", action: i.clear) } }
        .onDisappear { if i.running { i.toggle() } }
    }
}
