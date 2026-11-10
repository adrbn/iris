import AVFoundation
import Network
import NetworkExtension
import SwiftUI

/// Pulls full-resolution photos and videos off the glasses over their own hotspot:
/// BLE 0x39 → SSID, join it, GET app/getfilelist, download each new file, BLE 0x44, leave.
@MainActor
final class Media: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    /// The file being downloaded, for the progress card: nil while connecting.
    @Published private(set) var transfer: Transfer?
    struct Transfer: Equatable { var index: Int; var count: Int; var name: String; var received: Int64; var total: Int64 }

    static let folder = URL.documentsDirectory.appending(path: "Lunettes", directoryHint: .isDirectory)

    private let glasses: Glasses
    private let liveWifi: LiveWifi
    private var ssid: String?
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init(glasses: Glasses) {
        self.glasses = glasses
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        liveWifi = LiveWifi(glasses: glasses)
        glasses.onWifi = { [weak self] ssid in
            guard let self else { return }
            if self.busy { self.join(ssid) } else if glasses.live { self.liveWifi.start(ssid) }
        }
        glasses.onLiveOff = { [weak self] in
            guard let self, !self.busy else { return }
            self.liveWifi.stop()
            glasses.wifiDone()
        }
        reload()
    }

    func fetch() {
        guard !busy else { return }
        busy = true
        status = "Activation du Wi-Fi des lunettes…"
        glasses.wifiOn()
        Task {
            try? await Task.sleep(for: .seconds(15))
            if busy, ssid == nil { finish("Les lunettes n'ont pas activé leur Wi-Fi.") }
        }
    }

    /// Hyperlapse: the same video ×speed, without sound, saved next to it.
    func hyperlapse(_ url: URL, speed: Double = 8) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw URLError(.cannotDecodeContentData) }
        let comp = AVMutableComposition()
        let out = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try out.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        out.preferredTransform = try await track.load(.preferredTransform)
        out.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed))
        let dest = Self.folder.appending(path: url.deletingPathExtension().lastPathComponent + "-x\(Int(speed)).mp4")
        try? FileManager.default.removeItem(at: dest)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw URLError(.cannotCreateFile) }
        try await export.export(to: dest, as: .mp4)
        reload()
        return dest
    }

    func delete(_ urls: some Sequence<URL>) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    private func join(_ ssid: String) {
        guard busy, self.ssid == nil else { return }
        self.ssid = ssid
        status = "Connexion au Wi-Fi « \(ssid) »…"
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: Proto.wifiPassword, isWEP: false)
        config.joinOnce = true
        Task {
            // The SSID arrives 0.5 s after 0x39, before the hotspot beacons: joining right away gave
            // iOS's "Impossible de se connecter" on 08/11. Give it time, and one more try.
            for attempt in 1...2 {
                try? await Task.sleep(for: .seconds(attempt == 1 ? 4 : 6))
                do {
                    try await NEHotspotConfigurationManager.shared.apply(config)
                    Log.line("wifi: rejoint \(ssid) (essai \(attempt))")
                    break
                } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain
                            && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    break
                } catch {
                    Log.line("wifi: échec \(ssid) essai \(attempt) : \(error.localizedDescription)")
                    if attempt == 2 { finish("Wi-Fi refusé : \(error.localizedDescription)"); return }
                    status = "Wi-Fi pas encore prêt, nouvel essai…"
                }
            }
            await download()
        }
    }

    private func download() async {
        // The phone needs a few seconds on the new network, plus the local-network prompt the first time.
        var list: [Proto.MediaFile]?
        for attempt in 1...15 {
            status = "Lecture de la liste… (essai \(attempt))"
            if let (data, _) = try? await http.data(from: Proto.mediaBase.appending(path: "app/getfilelist")),
               let parsed = try? Proto.fileList(data) {
                list = parsed
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let list else { finish("Lunettes injoignables en Wi-Fi."); return }
        Log.line("wifi: \(list.count) fichiers")
        await probe()

        let todo = list.filter { local($0).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false }
        for (i, file) in todo.enumerated() {
            guard let destination = local(file), let source = remote(file) else { continue }
            // The list's "size" isn't in bytes ("0 Mo" for every file, 08/11): the bytes come from the download.
            status = "Téléchargement"
            transfer = Transfer(index: i + 1, count: todo.count, name: destination.lastPathComponent, received: 0, total: 0)
            do {
                try await save(source, to: destination)
            } catch {
                finish("Échec sur \(destination.lastPathComponent) : \(error.localizedDescription)")
                return
            }
            reload()
        }
        finish(todo.isEmpty ? "Rien de nouveau sur les lunettes." : "\(todo.count) fichier(s) récupéré(s).")
    }

    /// One file, with byte progress into `transfer`.
    private func save(_ source: URL, to destination: URL) async throws {
        var watch: NSKeyValueObservation?
        defer { watch?.invalidate() }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let task = http.downloadTask(with: source) { tmp, response, error in
                do {
                    if let error { throw error }
                    guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    done.resume()
                } catch { done.resume(throwing: error) }
            }
            watch = task.observe(\.countOfBytesReceived) { [weak self] task, _ in
                let received = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive
                Task { @MainActor in self?.transfer?.received = received; self?.transfer?.total = max(total, 0) }
            }
            task.resume()
        }
    }

    /// Looks for a live stream or settings API on the glasses' web server; results go to the journal.
    private func probe() async {
        status = "Exploration du serveur des lunettes…"
        for path in ["app/getproductinfo", "app/getmediainfo", "app/getdeviceattr", "app/getparamitems",
                     "app/getparamvalue?param=all", "app/capability", "app/getsdinfo", "app/getbatteryinfo", "app/getrecduration",
                     "", "index.html", "files/media.config", "livestream", "live", "stream", "video", "mjpeg"] {
            guard let url = URL(string: path, relativeTo: Proto.mediaBase) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            if let (data, response) = try? await http.data(for: request) {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
                Log.line("probe /\(path) \(code) \(type) \(String(decoding: data.prefix(400), as: UTF8.self))")
            } else {
                Log.line("probe /\(path) no answer")
            }
        }
        for port in [554, 8554, 5000, 8080, 8081, 2229, 3333, 6666, 7878, 9000, 1935] {
            Log.line("probe tcp \(port) \(await Self.open(port) ? "OPEN" : "closed")")
        }
    }

    private static func open(_ port: Int) async -> Bool {
        await withCheckedContinuation { done in
            let connection = NWConnection(host: "192.168.169.1", port: .init(integerLiteral: UInt16(port)), using: .tcp)
            var finished = false
            func end(_ result: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                done.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: end(true)
                case .failed, .waiting: end(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { end(false) }
        }
    }

    /// Always tell the glasses we're done (they switch the hotspot off) and give the phone its Wi-Fi back.
    private func finish(_ message: String) {
        if let ssid {
            glasses.wifiDone()
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        ssid = nil
        busy = false
        transfer = nil
        status = message
        reload()
    }

    private func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        files = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    /// The name comes from the glasses: keep only its last path component locally.
    private func local(_ file: Proto.MediaFile) -> URL? {
        let name = (file.name as NSString).lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return nil }
        return Self.folder.appending(path: name)
    }

    private func remote(_ file: Proto.MediaFile) -> URL? {
        let path = file.name.hasPrefix("/") ? String(file.name.dropFirst()) : file.name
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: encoded, relativeTo: Proto.mediaBase)
    }
}

extension URL {
    var isVideo: Bool { ["mp4", "mov", "avi"].contains(pathExtension.lowercased()) }
}

struct MediaSection: View {
    @ObservedObject var media: Media
    @ObservedObject var glasses: Glasses

    var body: some View {
        Section("Photos et vidéos des lunettes") {
            Button {
                media.fetch()
            } label: {
                Label(media.busy ? "Transfert…" : "Récupérer en Wi-Fi", systemImage: "wifi")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
            .disabled(media.busy || glasses.state != .ready)
            if !media.status.isEmpty { Text(media.status).font(.footnote).foregroundStyle(.secondary) }
            NavigationLink("Galerie (\(media.files.count))") { Gallery(media: media) }
        }
    }
}

struct Gallery: View {
    @ObservedObject var media: Media

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                ForEach(media.files, id: \.self) { url in
                    NavigationLink { MediaDetail(url: url, media: media) } label: { Thumbnail(url: url) }
                }
            }
        }
        .navigationTitle("Galerie")
        .overlay { if media.files.isEmpty { ContentUnavailableView("Rien pour l'instant", systemImage: "eyeglasses") } }
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .overlay(alignment: .bottomTrailing) {
                if url.isVideo { Image(systemName: "play.fill").foregroundStyle(.white).shadow(radius: 2).padding(6) }
            }
            .clipped()
            .task { image = await Self.make(url) }
    }

    static func make(_ url: URL) async -> UIImage? {
        if url.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            return (try? await generator.image(at: .zero)).map { UIImage(cgImage: $0.image) }
        }
        return await UIImage(contentsOfFile: url.path)?.byPreparingThumbnail(ofSize: CGSize(width: 400, height: 400))
    }
}

/// Full screen, swipe left/right between items; the toolbar acts on the one shown.
struct MediaDetail: View {
    @ObservedObject var media: Media
    @State private var current: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var making = ""
    @State private var reading = false

    init(url: URL, media: Media) {
        self.media = media
        _current = State(initialValue: url)
    }

    var body: some View {
        TabView(selection: $current) {
            ForEach(media.files, id: \.self) { url in
                MediaPage(url: url, shown: current == url).tag(Optional(url))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(current.map { "\((media.files.firstIndex(of: $0) ?? 0) + 1) sur \(media.files.count)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { if !making.isEmpty { Text(making).padding(8).background(.thinMaterial, in: Capsule()).padding() } }
        .sheet(isPresented: $reading) { if let current { ReaderSheet(url: current) } }
        .onChange(of: media.files) { if media.files.isEmpty { dismiss() } }
        .toolbar {
            if let url = current {
                if url.isVideo {
                    Button {
                        making = "Hyperlapse en cours…"
                        Task {
                            do { making = "Créé : " + (try await media.hyperlapse(url)).lastPathComponent }
                            catch { making = "Échec : \(error.localizedDescription)" }
                        }
                    } label: { Image(systemName: "hare") }
                } else {
                    Button { reading = true } label: { Image(systemName: "text.viewfinder") }
                }
                ShareLink(item: url)
                Button(role: .destructive) {
                    let files = media.files, i = files.firstIndex(of: url) ?? 0
                    current = files.indices.contains(i + 1) ? files[i + 1] : (i > 0 ? files[i - 1] : nil)
                    media.delete([url])
                } label: { Image(systemName: "trash") }
            }
        }
    }
}

/// One page: the photo, or a video that plays only while it's the page shown.
private struct MediaPage: View {
    let url: URL
    let shown: Bool

    var body: some View {
        Group {
            if url.isVideo {
                IrisVideoPlayer(url: url, shown: shown)
            } else if let image = UIImage(contentsOfFile: url.path) {
                ZoomableImage(image: image)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
