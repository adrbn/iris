import ShazamKit
import AVFoundation
import SwiftUI

@main
struct IrisApp: App {
    var body: some Scene { WindowGroup { HomeView() } }
}

struct Shot: Identifiable {
    let id = UUID()
    /// nil for a voice question answered without looking.
    var image: UIImage? = nil
    var jpeg: Data? = nil
    let date = Date()
    var question = ""
    /// What the UI shows instead of the (long) question, e.g. "Guide".
    var title = ""
    var answer = ""
}

/// What a glasses gesture can trigger in Iris.
enum GestureAction: String, CaseIterable {
    case none, ask, guide, photo, video, repeatAnswer, silence, macNext, macPrev, macPlay, shazam
    var label: String {
        switch self {
        case .none: "Rien (firmware)"
        case .ask: "Demander à Iris"
        case .guide: "Guide"
        case .photo: "Photo"
        case .video: "Vidéo marche/arrêt"
        case .repeatAnswer: "Répéter la réponse"
        case .silence: "Faire taire Iris"
        case .macNext: "Mac : suivant →"
        case .macPrev: "Mac : précédent ←"
        case .macPlay: "Mac : espace (lecture)"
        case .shazam: "Quelle musique ?"
        }
    }
    static let gestures = [("tap", "Tap"), ("double", "Double tap"), ("triple", "Triple tap"),
                           ("front", "Glissé avant"), ("back", "Glissé arrière"), ("nod", "Hochement"), ("shake", "Secouement")]
}

@MainActor
final class Session: ObservableObject {
    @Published var shots: [Shot] = []
    @Published var busy = false
    @Published var notice = ""
    /// What the glasses' mic heard, live.
    @Published var hearing = ""
    let glasses = Glasses()
    lazy var media = Media(glasses: glasses)
    lazy var notes: VoiceNotes = {
        let notes = VoiceNotes()
        notes.summarize = { [weak self] text in
            guard let self else { return nil }
            let client = AIClient(baseURL: self.baseURL, model: Providers.model(for: self.baseURL, fallback: self.model), apiKey: Keychain.read(for: self.baseURL), prompt: self.prompt)
            return try? await Brain.text("Résume cette note vocale en une phrase courte, en français, sans préambule :\n\n" + text, apple: self.appleBrain, client: client)
        }
        return notes
    }()
    lazy var liveServer = LiveServer(glasses: glasses)
    private lazy var liveStatus = LiveStatus(glasses: glasses)
    private let voice = AVSpeechSynthesizer()
    private let spoken = SpeechDone()
    /// A spoken voice answer reopens the iPhone mic once it's said, so you can answer back; the
    /// 10-minute memory in analyze() keeps the thread. Nothing said within 6 s ends the conversation.
    private var converse = false
    private let ears = Ears()
    private let guide = Guide()
    let memory = Memory()
    let journal = Journal()
    private var memoryPending = false
    private var lastMemory = Date.distantPast
    private var voiceStarted: Date?

    @AppStorage("baseURL") var baseURL = "https://api.openai.com/v1"
    @AppStorage("model") var model = "gpt-4o-mini"
    @AppStorage("prompt") var prompt = "Tu es Iris, l'assistant de mes lunettes. L'image est ce que je regarde. Réponds en français, en une ou deux phrases courtes faites pour être lues à voix haute. S'il y a du texte utile, lis-le."
    /// Apple's on-device model first: free, and nothing leaves the phone.
    @AppStorage("appleBrain") var appleBrain = true
    @AppStorage("speak") var speak = true
    /// Off by default: a photo stays on the phone unless the user asks for an analysis.
    @AppStorage("autoAnalyze") var autoAnalyze = false

    init() {
        _ = liveStatus
        // "Jamais" was set on 08/11 only to stop the photo-on-every-press bug, fixed in bb2c25c.
        if !UserDefaults.standard.bool(forKey: "sendImageReset1") {
            UserDefaults.standard.set(true, forKey: "sendImageReset1")
            UserDefaults.standard.set("auto", forKey: "sendImage")
        }
        // gemini-3.8-flash never answered once (every call timed out, 08/11): drop it if it was picked.
        let gemini = "model:generativelanguage.googleapis.com"
        if UserDefaults.standard.string(forKey: gemini)?.contains("gemini-3.8-flash") == true {
            UserDefaults.standard.removeObject(forKey: gemini)
        }
        glasses.onPhoto = { [weak self] jpeg in self?.handle(jpeg) }
        glasses.onVoiceStart = { [weak self] in self?.listen() }
        glasses.onVoiceData = { [weak self] data in self?.ears.feed(data) }
        glasses.onVoiceEnd = { [weak self] in self?.ears.finish() }
        ears.onPartial = { [weak self] text in self?.hearing = text }
        voice.delegate = spoken
        spoken.onDone = { [weak self] in
            guard let self, self.converse, !self.voice.isSpeaking else { return }
            self.converse = false
            self.askByPhone(followUp: true)
        }
        glasses.onGesture = { [weak self] g in self?.gesture(g) }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                self?.memoryTick()
            }
        }
        // Test hook: `devicectl … process launch com.adrbn.iris -liveServer` starts the remote view without touching the screen.
        if ProcessInfo.processInfo.arguments.contains("-shazam") { shazam() }
        if ProcessInfo.processInfo.arguments.contains("-selftest") { Task { await SelfTest.run() } }
        if ProcessInfo.processInfo.arguments.contains("-liveServer") { liveServer.start(); glasses.setLive(true) }
    }

    /// "Jarvis": the glasses start streaming their mic (wake word, button, or startListening).
    /// Take a photo right away so it's ready when the question ends (capture takes ~2.3 s).
    private func listen() {
        voiceStarted = Date()
        hearing = ""
        ears.onSilence = { [weak self] in self?.glasses.stopListening() }
        ears.start { [weak self] question in self?.ask(question) }
    }

    /// Home button: the iPhone mic (the glasses won't open theirs on request). Tap again to end early.
    @Published private(set) var phoneListening = false
    func askByPhone(followUp: Bool = false) {
        if phoneListening { ears.finish(); return }
        phoneListening = true
        voiceStarted = Date()
        hearing = ""
        ears.onSilence = nil
        ears.startPhone { [weak self] question in
            guard let self else { return }
            self.phoneListening = false
            if followUp, question.isEmpty { self.voiceStarted = nil; return }   // no reply: conversation over
            self.ask(question)
        }
    }

    /// Photo translation screen: a fresh photo, then the brain reads and translates its text.
    func translatePhoto() {
        voiceStarted = Date()
        glasses.takeAIPhoto()
        ask(PhotoTranslate.prompt, title: PhotoTranslate.title)
    }

    /// Audio guide: photo now, GPS + Wikipedia meanwhile, then the brain narrates.
    func tour(said: String = "") {
        if voiceStarted == nil { voiceStarted = Date(); glasses.takeAIPhoto() }
        notice = "Guide : je regarde autour…"
        Task {
            let prompt = await guide.prompt()
            notice = ""
            ask(prompt, title: said.isEmpty ? "Guide" : "Guide · « \(said) »")
        }
    }

    private func ask(_ question: String, title: String = "") {
        if title.isEmpty, question.lowercased().contains("guide") { tour(said: question); return }
        // "Shazam", "quelle est cette musique" → Shazam itself; the AI would answer it can't hear (08/11).
        if title.isEmpty, Self.isShazam(question) { hearing = question; voiceStarted = nil; shazam(); return }
        let tourSince = voiceStarted   // tour() has already taken its photo
        voiceStarted = nil
        if title.isEmpty { hearing = question }
        guard !question.isEmpty else { notice = "Je n'ai rien entendu."; return }
        Task {
            var since = tourSince ?? .distantPast
            if title.isEmpty {   // voice question: a photo only if answering needs to see
                let mode = UserDefaults.standard.string(forKey: "sendImage") ?? "auto"
                let look = mode == "always" ? true : mode == "never" ? false : await Intent.decide(question)
                guard look else {
                    shots.insert(Shot(question: question), at: 0)
                    analyze(shots[0].id)
                    return
                }
                since = Date()
                voiceStarted = since   // keeps handle() from auto-analyzing this photo on its own
                glasses.takeAIPhoto()
            }
            for _ in 0..<20 where shots.first.map({ $0.jpeg == nil || $0.date < since }) ?? true {
                try? await Task.sleep(for: .milliseconds(400))
            }
            voiceStarted = nil
            guard let i = shots.firstIndex(where: { $0.jpeg != nil && $0.date >= since }) else { notice = "Pas de photo pour répondre."; return }
            shots[i].question = question
            shots[i].title = title
            analyze(shots[i].id)
        }
    }

    func writeJournal() {
        let client = AIClient(baseURL: baseURL, model: Providers.model(for: baseURL, fallback: model), apiKey: Keychain.read(for: baseURL), prompt: prompt)
        journal.write(memory: memory.items, apple: appleBrain, client: client)
    }

    /// Default from IRIS_MAC_REMOTE in scripts/local.env (install.sh puts it in Info.plist).
    @AppStorage("macRemote2") var macRemote = Bundle.main.object(forInfoDictionaryKey: "IrisMacRemote") as? String ?? ""

    /// Iris Live on the Mac (mac/main.swift) turns these into key presses.
    private func mac(_ action: String) {
        guard !macRemote.isEmpty, let url = URL(string: macRemote + "/" + action) else {
            notice = "Télécommande Mac non configurée"
            return
        }
        Task {
            let code = (try? await URLSession.shared.data(from: url)).map { ($0.1 as? HTTPURLResponse)?.statusCode ?? 0 } ?? 0
            if code != 200 { notice = "Mac injoignable (\(code)) : autorise Iris Live (Accessibilité) sur le Mac" }
        }
    }

    /// ShazamKit through the iPhone mic; the answer is spoken in the glasses.
    /// Needs the ShazamKit App Service enabled for com.adrbn.iris on developer.apple.com.
    static func isShazam(_ question: String) -> Bool {
        let q = question.lowercased().replacingOccurrences(of: "’", with: "'")
        return ["shazam", "chazam", "shazame", "quelle musique", "quelle chanson", "cette musique", "cette chanson",
                "ce morceau", "quel morceau", "qui chante", "quel titre", "reconnais la musique", "écoute la musique"].contains { q.contains($0) }
    }

    func shazam() {
        notice = "J'écoute la musique…"
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        Task {
            let session = SHManagedSession()
            let result = await session.result()
            switch result {
            case .match(let m):
                let item = m.mediaItems.first
                let line = [item?.title, item?.artist].compactMap { $0 }.joined(separator: ", de ")
                notice = "♪ " + line
                Log.line("shazam: \(line)")
                say(line)
            case .noMatch: notice = "Musique pas reconnue."; Log.line("shazam: rien")
            case .error(let e, _): notice = "Shazam : \(e.localizedDescription)"; Log.line("shazam erreur \(e)")
            @unknown default: notice = ""
            }
        }
    }

    private func gesture(_ g: String) {
        let action = GestureAction(rawValue: UserDefaults.standard.string(forKey: "gesture.\(g)") ?? "") ?? .none
        Log.line("geste \(g) → \(action.rawValue)")
        switch action {
        case .none: break
        case .ask: glasses.listening ? glasses.stopListening() : glasses.startListening()
        case .guide: tour()
        case .photo: glasses.takeAIPhoto()
        case .video: glasses.toggleVideo()
        case .repeatAnswer: if let a = shots.first(where: { !$0.answer.isEmpty && $0.answer != "…" })?.answer { say(a) }
        case .silence: voice.stopSpeaking(at: .immediate)
        case .macNext: mac("next")
        case .macPrev: mac("prev")
        case .macPlay: mac("play")
        case .shazam: shazam()
        }
    }

    /// Memory photo when due, only if worn, connected and nothing else is waiting for a photo.
    private func memoryTick() {
        guard memory.on, glasses.state == .ready, glasses.worn != false, voiceStarted == nil,
              Date().timeIntervalSince(lastMemory) >= Double(memory.minutes * 60) else { return }
        lastMemory = Date()
        memoryPending = true
        glasses.takeAIPhoto()
    }

    private func handle(_ jpeg: Data) {
        if memoryPending { memoryPending = false; memory.add(jpeg); return }
        guard let image = UIImage(data: jpeg) else { notice = "Image illisible (\(jpeg.count) octets reçus)"; return }
        notice = ""
        shots.insert(Shot(image: image, jpeg: jpeg), at: 0)
        if autoAnalyze, voiceStarted == nil { analyze(shots[0].id) }
    }

    func analyze(_ id: UUID) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        let jpeg = shots[i].jpeg
        // Short conversation memory: the last answered exchanges of the past 10 minutes, oldest first,
        // so "et lui, c'est qui ?" refers to the previous answer.
        let recent = shots.dropFirst(i + 1).filter { !$0.question.isEmpty && !$0.answer.isEmpty && $0.answer != "…" && !$0.answer.hasPrefix("⚠︎")
            && Date().timeIntervalSince($0.date) < 600 }.prefix(4).reversed()
        let context = recent.isEmpty ? "" : "Échanges précédents (contexte) :\n" + recent.map { "- Moi : \($0.question)\n  Toi : \($0.answer)" }.joined(separator: "\n") + "\n\nNouvelle question : "
        let question = shots[i].question.isEmpty ? nil : context + shots[i].question
        let apple = appleBrain
        // Whether a voice question needs the photo was decided in ask(): no photo, no image.
        let useImage = jpeg != nil
        let client = AIClient(baseURL: baseURL, model: Providers.model(for: baseURL, fallback: model), apiKey: Keychain.read(for: baseURL), prompt: prompt)
        Log.line("ia: photo \(useImage ? "envoyée" : "pas envoyée") · apple=\(apple) · service \(Keychain.host(baseURL))/\(client.model.isEmpty ? "aucun modèle" : client.model)")
        shots[i].answer = "…"
        busy = true
        Task {
            let answer: String
            do {
                if let jpeg {
                    answer = try await Brain.answer(question: question, jpeg: jpeg, apple: apple, client: client)
                } else {
                    answer = try await Brain.text("Réponds brièvement, comme à l'oral, en français, en texte simple sans mise en forme (pas d'astérisques, pas de listes).\n\n" + (question ?? ""), apple: apple, client: client)
                }
            } catch { answer = "⚠︎ " + error.localizedDescription }
            busy = false
            Log.line("ia réponse: \(answer.prefix(200))")
            if let i = shots.firstIndex(where: { $0.id == id }) {
                shots[i].answer = answer
                if !answer.hasPrefix("⚠︎") { Journal.record(question: shots[i].title.isEmpty ? shots[i].question : shots[i].title, answer: answer) }
            }
            // An error is said too, short: silence after a question looks like nothing happened.
            converse = speak && !answer.hasPrefix("⚠︎") && question != nil && title(of: id).isEmpty
            if speak { say(answer.hasPrefix("⚠︎") ? "Erreur. " + (answer.dropFirst(2).split(separator: ".").first.map(String.init) ?? "") : answer) }
        }
    }

    private func title(of id: UUID) -> String { shots.first { $0.id == id }?.title ?? "" }

    private func say(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // Markdown read aloud ("astérisque astérisque") or shown raw: strip it for the voice.
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")
        let u = AVSpeechUtterance(string: plain)
        u.voice = AVSpeechSynthesisVoice.best()
        Log.line("voix: \(plain.count) caractères")
        voice.speak(u)
    }
}

/// Tells Session when the voice has finished, to reopen the mic for a reply.
final class SpeechDone: NSObject, AVSpeechSynthesizerDelegate {
    var onDone: (@MainActor () -> Void)?
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Log.line("voix: fin")
        Task { @MainActor in self.onDone?() }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Log.line("voix: coupée avant la fin")
    }
}
