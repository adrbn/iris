import SwiftUI

/// Evening journal: today's memory photos (what Vision saw, at what time) + the questions asked
/// to Iris → a short diary page written by the brain, saved as Documents/Journal/<date>.md.
@MainActor
final class Journal: ObservableObject {
    struct Exchange: Codable { let date: Date; let question: String; let answer: String }

    @Published private(set) var pages: [URL] = []
    @Published private(set) var busy = false
    @Published var error = ""

    static let folder = URL.documentsDirectory.appending(path: "Journal", directoryHint: .isDirectory)
    private static let log = URL.documentsDirectory.appending(path: "echanges.jsonl")

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        reload()
    }

    /// Every answered question is kept (one JSON line), so the journal can quote the day.
    static func record(question: String, answer: String) {
        guard let line = try? JSONEncoder().encode(Exchange(date: Date(), question: question, answer: answer)) else { return }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try? h.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: log)
        }
    }

    static func today(_ memory: [Memory.Item], day: Date = Date()) -> String {
        let cal = Calendar.current
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        let seen = memory.filter { cal.isDate($0.date, inSameDayAs: day) }.reversed().map {
            "- \(time($0.date)) : \($0.labels.prefix(5).joined(separator: ", "))\($0.text.isEmpty ? "" : " ; texte : \($0.text.prefix(80))")"
        }
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
        let asked = lines.compactMap { try? JSONDecoder().decode(Exchange.self, from: Data($0.utf8)) }
            .filter { cal.isDate($0.date, inSameDayAs: day) }
            .map { "- \(time($0.date)) : « \($0.question.prefix(120)) » → \($0.answer.prefix(200))" }
        return """
        Écris la page de journal de ma journée, en français, à la première personne, 8 à 12 phrases, ton simple et vivant. \
        Appuie-toi uniquement sur ces traces ; n'invente aucun fait, et dis-le quand une période est vide.

        Ce que mes lunettes ont vu (reconnaissance automatique, approximative) :
        \(seen.isEmpty ? "rien" : seen.joined(separator: "\n"))

        Ce que j'ai demandé à mon assistant :
        \(asked.isEmpty ? "rien" : asked.joined(separator: "\n"))
        """
    }

    func write(memory: [Memory.Item], apple: Bool, client: AIClient) {
        busy = true
        error = ""
        let prompt = Self.today(memory)
        Task {
            defer { busy = false }
            do {
                let text = try await Brain.text(prompt, apple: apple, client: client)
                let name = Date().formatted(.iso8601.year().month().day()) + ".md"
                try text.write(to: Self.folder.appending(path: name), atomically: true, encoding: .utf8)
                reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func reload() {
        pages = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

struct JournalView: View {
    @ObservedObject var journal: Journal
    let write: () -> Void

    var body: some View {
        List {
            Section {
                Button(journal.busy ? "Écriture…" : "Écrire la page d'aujourd'hui", action: write).disabled(journal.busy)
                if !journal.error.isEmpty { Text(journal.error).foregroundStyle(.red) }
            } footer: {
                Text("À partir de la mémoire photo et de tes questions à Iris du jour. Avec l'IA d'Apple activée, rien ne sort du téléphone.")
            }
            ForEach(journal.pages, id: \.self) { url in
                NavigationLink(url.deletingPathExtension().lastPathComponent) {
                    ScrollView { Text((try? String(contentsOf: url, encoding: .utf8)) ?? "").padding().textSelection(.enabled) }
                        .navigationTitle(url.deletingPathExtension().lastPathComponent)
                        .toolbar { ShareLink(item: url) }
                }
            }
        }
        .navigationTitle("Journal")
    }
}
