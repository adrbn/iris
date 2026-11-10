import SwiftUI
import Vision

/// Photographic memory, entirely on the phone: a glasses photo every few minutes while they're worn,
/// tagged by Vision (objects + text), searchable later ("keys", "passeport"…). Nothing is sent anywhere.
@MainActor
final class Memory: ObservableObject {
    struct Item: Codable, Identifiable {
        var id: String { file }
        let file: String
        let date: Date
        let labels: [String]
        let text: String
    }

    @Published private(set) var items: [Item] = []
    @AppStorage("memoryOn") var on = false
    @AppStorage("memoryMinutes") var minutes = 5

    static let folder = URL.documentsDirectory.appending(path: "Memoire", directoryHint: .isDirectory)
    private static let index = folder.appending(path: "index.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.index) {
            items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
        }
    }

    func add(_ jpeg: Data) {
        let date = Date()
        let file = "\(Int(date.timeIntervalSince1970)).jpg"
        try? jpeg.write(to: Self.folder.appending(path: file))
        Task.detached(priority: .utility) {
            let (labels, text) = Self.tags(jpeg)
            await MainActor.run {
                self.items.insert(Item(file: file, date: date, labels: labels, text: text), at: 0)
                self.save()
                Log.line("memoire: \(labels.joined(separator: ",")) | \(text.prefix(40))")
            }
        }
    }

    func search(_ query: String) -> [Item] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.labels.contains { $0.contains(q) } || $0.text.lowercased().contains(q) }
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: Self.folder.appending(path: item.file))
        items.removeAll { $0.file == item.file }
        save()
    }

    func deleteAll() {
        items.forEach { try? FileManager.default.removeItem(at: Self.folder.appending(path: $0.file)) }
        items = []
        save()
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: Self.index)
    }

    /// Vision's object classes are English identifiers ("key", "cup"); OCR keeps the original text.
    nonisolated static func tags(_ jpeg: Data) -> ([String], String) {
        let classify = VNClassifyImageRequest()
        let read = VNRecognizeTextRequest()
        read.recognitionLanguages = ["fr-FR", "en-US", "it-IT"]
        try? VNImageRequestHandler(data: jpeg).perform([classify, read])
        let labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(8).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let text = (read.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return (Array(labels), text)
    }
}

struct MemoryView: View {
    @ObservedObject var memory: Memory
    @State private var query = ""
    @State private var confirmWipe = false

    var body: some View {
        List {
            Section {
                Toggle("Mémoire photo", isOn: $memory.on)
                Stepper("Une photo toutes les \(memory.minutes) min", value: $memory.minutes, in: 1...60)
            } footer: {
                Text("Seulement quand les lunettes sont portées et Iris ouverte (iOS endort l'app en arrière-plan). Tout reste sur l'iPhone. Les objets sont reconnus en anglais : cherche « key », « cup », « bag »… Le texte lu, lui, garde sa langue.")
            }
            ForEach(memory.search(query)) { item in
                HStack(alignment: .top) {
                    if let image = UIImage(contentsOfFile: Memory.folder.appending(path: item.file).path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 140).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text(item.labels.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                        if !item.text.isEmpty { Text(item.text).font(.footnote).lineLimit(3) }
                    }
                }
                .swipeActions { Button("Supprimer", role: .destructive) { memory.delete(item) } }
            }
            if !memory.items.isEmpty {
                Button("Tout effacer (\(memory.items.count))", role: .destructive) { confirmWipe = true }
            }
        }
        .searchable(text: $query, prompt: "key, passeport, menu…")
        .navigationTitle("Mémoire")
        .confirmationDialog("Effacer toutes les photos de la mémoire ? Irréversible.", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Tout effacer", role: .destructive) { memory.deleteAll() }
        }
    }
}
