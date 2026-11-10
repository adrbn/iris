import Combine
import Foundation
import Network

/// Serves the glasses' live view as MJPEG over HTTP, so any browser can watch it:
/// on the same Wi-Fi, or from anywhere through Tailscale (phone's 100.x address).
/// Every URL carries a random token: without it, the server answers 404.
@MainActor
final class LiveServer: ObservableObject {
    static let port: UInt16 = 8080
    @Published private(set) var running = false
    @Published private(set) var viewers = 0
    @Published private(set) var error = ""

    let token: String = {
        if let saved = UserDefaults.standard.string(forKey: "liveToken") { return saved }
        let fresh = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(fresh, forKey: "liveToken")
        return fresh
    }()

    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var latest: Data?
    private var watch: AnyCancellable?

    init(glasses: Glasses) {
        watch = glasses.$liveJPEG.compactMap { $0 }.sink { [weak self] jpeg in self?.push(jpeg) }
    }

    /// Addresses a viewer can type, Tailscale first.
    var urls: [String] {
        Self.addresses().sorted { $0.hasPrefix("100.") && !$1.hasPrefix("100.") }
            .map { "http://\($0):\(Self.port)/\(token)/" }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .failed(let e) = state { self?.error = e.localizedDescription; self?.stop() }
                }
            }
            l.start(queue: .main)
            listener = l
            running = true
            error = ""
            Log.line("live server: \(urls.joined(separator: " "))")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        streams.values.forEach { $0.cancel() }
        streams = [:]
        viewers = 0
        running = false
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            Task { @MainActor in self?.route(path, c) }
        }
    }

    private func route(_ path: String, _ c: NWConnection) {
        let base = "/\(token)/"
        switch path {
        case base:
            reply(c, "text/html; charset=utf-8", Data(Self.page.utf8))
        case base + "frame.jpg":
            reply(c, "image/jpeg", latest ?? Data())
        case base + "stream":
            let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=iris\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let id = ObjectIdentifier(c)
            streams[id] = c
            viewers = streams.count
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: Task { @MainActor in self?.streams[id] = nil; self?.viewers = self?.streams.count ?? 0 }
                default: break
                }
            }
            if let latest { send(latest, to: c) }
        default:
            reply(c, "text/plain", Data("404".utf8), status: "404 Not Found")
        }
    }

    private func push(_ jpeg: Data) {
        latest = jpeg
        streams.values.forEach { send(jpeg, to: $0) }
    }

    private func send(_ jpeg: Data, to c: NWConnection) {
        let head = "--iris\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
        c.send(content: Data(head.utf8) + jpeg + Data("\r\n".utf8), completion: .contentProcessed { error in
            if error != nil { c.cancel() }
        })
    }

    private func reply(_ c: NWConnection, _ type: String, _ body: Data, status: String = "200 OK") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private static let page = """
    <!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>Iris en direct</title>
    <style>body{margin:0;background:#000;display:grid;place-items:center;min-height:100vh}img{max-width:100%;max-height:100vh}</style>
    <img src="stream" alt="Iris">
    """

    private static func addresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return out }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254"), !out.contains(ip) { out.append(ip) }
        }
        return out
    }
}
