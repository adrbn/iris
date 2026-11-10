import AVFoundation
import Speech
import SwiftUI

/// Voice notes: the iPhone mic records (m4a) and transcribes live, on the phone; long notes get a
/// one-line summary from the brain. Saved in Documents/Notes (notes.json + one audio file each).
@MainActor
final class VoiceNotes: ObservableObject {
    struct Note: Codable, Identifiable {
        var id = UUID()
        var date = Date()
        var text: String
        var summary = ""
        var audio: String
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var recording = false
    @Published private(set) var live = ""
    @Published var error = ""
    /// Set by Session: the brain that writes summaries.
    var summarize: ((String) async -> String?)?

    static let folder = URL.documentsDirectory.appending(path: "Notes", directoryHint: .isDirectory)
    private static let index = folder.appending(path: "notes.json")
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var file: AVAudioFile?
    private var audioName = ""

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        notes = (try? JSONDecoder().decode([Note].self, from: Data(contentsOf: Self.index))) ?? []
    }

    func toggle() { recording ? stop() : start() }

    private func start() {
        error = ""
        live = ""
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.duckOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            audioName = "note-\(Int(Date().timeIntervalSince1970)).m4a"
            file = try AVAudioFile(forWriting: Self.folder.appending(path: audioName),
                                   settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                              AVNumberOfChannelsKey: format.channelCount])
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            // On the phone there's no one-minute cap; the network recognizer cuts long notes.
            if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
            self.request = request
            task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString else { return }
                Task { @MainActor in self?.live = text }
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                Task { @MainActor in
                    self?.request?.append(buffer)
                    try? self?.file?.write(from: buffer)
                }
            }
            try engine.start()
            recording = true
            Log.line("notes: enregistrement")
        } catch {
            self.error = "Micro indisponible : \(error.localizedDescription)"
            Log.line("notes: échec \(error.localizedDescription)")
        }
    }

    private func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recording = false
        Task {
            try? await Task.sleep(for: .seconds(1))   // the last words arrive after endAudio
            task?.cancel()
            file = nil
            let text = live.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = Note(text: text.isEmpty ? "(rien entendu)" : text, audio: audioName)
            notes.insert(note, at: 0)
            save()
            live = ""
            guard text.count > 160, let summary = await summarize?(text) else { return }
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i].summary = summary; save() }
        }
    }

    func delete(_ offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: Self.folder.appending(path: notes[i].audio)) }
        notes.remove(atOffsets: offsets)
        save()
    }

    func audioURL(_ note: Note) -> URL { Self.folder.appending(path: note.audio) }

    private func save() { try? JSONEncoder().encode(notes).write(to: Self.index) }
}

struct VoiceNotesView: View {
    @ObservedObject var notes: VoiceNotes
    @State private var player: AVAudioPlayer?
    @State private var playing: UUID?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Button(action: notes.toggle) {
                        Image(systemName: notes.recording ? "stop.fill" : "mic.fill")
                            .font(.title.weight(.semibold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 84, height: 84)
                            .background(notes.recording ? Color.red : Theme.accent, in: Circle())
                            .symbolEffect(.pulse, isActive: notes.recording)
                    }
                    .buttonStyle(Pressable())
                    .accessibilityLabel(notes.recording ? "Arrêter la note" : "Nouvelle note vocale")
                    Text(notes.recording ? (notes.live.isEmpty ? "Je t'écoute…" : notes.live) : "Touche pour dicter une note")
                        .font(notes.recording ? .body : .footnote)
                        .foregroundStyle(notes.recording ? Theme.ink : Theme.muted)
                        .multilineTextAlignment(.center)
                    if !notes.error.isEmpty { Text(notes.error).font(.footnote).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .listRowBackground(Theme.surface)

            Section {
                ForEach(notes.notes) { note in
                    HStack(alignment: .top, spacing: 12) {
                        Button { play(note) } label: {
                            Image(systemName: playing == note.id ? "pause.fill" : "play.fill")
                                .font(.footnote.weight(.bold)).foregroundStyle(Theme.ink)
                                .frame(width: 36, height: 36).background(Theme.surface2, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playing == note.id ? "Pause" : "Écouter")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.date, format: .dateTime.day().month().hour().minute())
                                .font(Theme.mono()).foregroundStyle(Theme.muted)
                            if !note.summary.isEmpty { Text(note.summary).font(.callout.weight(.semibold)).foregroundStyle(Theme.ink) }
                            Text(note.text).font(.subheadline).foregroundStyle(note.summary.isEmpty ? Theme.ink : Theme.muted)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu { ShareLink(item: note.text); ShareLink(item: notes.audioURL(note)) }
                }
                .onDelete(perform: notes.delete)
            } header: {
                if !notes.notes.isEmpty { Text("\(notes.notes.count) note(s)") }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Notes vocales")
        .onDisappear { player?.stop(); playing = nil }
    }

    private func play(_ note: VoiceNotes.Note) {
        if playing == note.id { player?.stop(); playing = nil; return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(contentsOf: notes.audioURL(note))
        player?.play()
        playing = player == nil ? nil : note.id
    }
}
