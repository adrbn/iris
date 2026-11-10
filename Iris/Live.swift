import SwiftUI

/// Live view from the glasses' camera. Tries the firmware stream first, then a BLE photo burst.
struct LiveView: View {
    @ObservedObject var glasses: Glasses
    @ObservedObject var server: LiveServer
    @State private var opened = Date()

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let data = glasses.liveJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if glasses.state != .ready {
                    Text("Lunettes non connectées : allume-les, puis reviens sur cet écran.").foregroundStyle(.white).padding()
                } else {
                    ProgressView("En attente d'image…")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(1, context.date.timeIntervalSince(opened))
                Text("\(glasses.liveFrames) images · \(String(format: "%.2f", Double(glasses.liveFrames) / seconds)) i/s · "
                     + (glasses.liveBurst ? "rafale BLE" : "flux natif"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if glasses.liveBurst {
                Text("En attendant le flux Wi-Fi des lunettes, Iris enchaîne des photos Bluetooth. L'iPhone rejoint leur Wi-Fi et cherche la vidéo ; tout est noté dans le journal.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Regarder à distance", isOn: Binding(get: { server.running }, set: { $0 ? server.start() : server.stop() }))
            if server.running {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(server.urls, id: \.self) { url in
                        HStack {
                            Text(url).font(.footnote).textSelection(.enabled)
                            Spacer()
                            ShareLink(item: URL(string: url)!) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                    Text("\(server.viewers) spectateur(s). L'adresse en 100.x marche de partout avec Tailscale allumé sur l'iPhone et l'autre appareil ; les autres, sur le même Wi-Fi seulement. Le live continue même si tu quittes cet écran ; laisse Iris ouverte, iOS peut couper le serveur en arrière-plan.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !server.error.isEmpty { Text(server.error).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding()
        .navigationTitle("Aperçu en direct")
        .onAppear { opened = .now; glasses.setLive(true) }
        .onDisappear { glasses.setLive(false); server.stop() }
    }
}
