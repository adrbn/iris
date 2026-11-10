import SwiftUI

/// Shows Documents/iris-log.txt inside the app, newest line first. Refreshes on appear and every 2 s.
/// Monospaced on purpose: the log is full of hex BLE frames that only line up in a fixed-width font.
struct LogView: View {
    @State private var text = ""
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Vide." : text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Journal technique")
        .toolbar {
            ShareLink(item: Log.url)
            Button("Vider") { try? FileManager.default.removeItem(at: Log.url); text = "" }
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in load() }
    }

    private func load() {
        let raw = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        text = raw.split(separator: "\n").reversed().joined(separator: "\n")
    }
}
