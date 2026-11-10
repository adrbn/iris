import Foundation
import Network
import NetworkExtension

/// Live video over the glasses' hotspot. Verified 2026-11-07: BLE 0x67 '1' → ack 0x67 01, then
/// 0x25 with the hotspot SSID. What the glasses serve on it is still unknown, so this joins the
/// hotspot and tries every likely source; any byte stream containing JPEGs (MJPEG over HTTP,
/// raw TCP, UDP) is cut on FFD8…FFD9 and shown. Everything it sees goes to the journal.
@MainActor
final class LiveWifi {
    private let glasses: Glasses
    private var ssid: String?
    private var found = false
    private var tasks: [URLSessionDataTask] = []
    private var connections: [NWConnection] = []
    private var listeners: [NWListener] = []
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()

    static let httpPaths = ["", "live", "stream", "video", "mjpeg", "?action=stream", "videostream.cgi", "live.mjpg",
                            "app/live", "app/stream", "app/getlivestream", "app/startlive", "app/preview", "preview", "cam.mjpeg"]
    static let tcpPorts: [UInt16] = [554, 8554, 3333, 2229, 6666, 7878, 8080, 8081, 9000, 5000, 1935, 8000, 2223, 2224]
    static let udpPorts: [UInt16] = [2224, 2223, 6666, 7777, 8000, 5000, 1234, 3333, 8080, 6000, 10000]

    init(glasses: Glasses) { self.glasses = glasses }

    func start(_ ssid: String) {
        guard self.ssid == nil else { return }
        self.ssid = ssid
        found = false
        Log.line("livewifi: join \(ssid)")
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: Proto.wifiPassword, isWEP: false)
        config.joinOnce = true
        Task {
            do { try await NEHotspotConfigurationManager.shared.apply(config) } catch let e as NSError
                where e.domain == NEHotspotConfigurationErrorDomain && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            } catch {
                Log.line("livewifi: join refusé \(error.localizedDescription)"); return
            }
            try? await Task.sleep(for: .seconds(3))
            listenUDP()
            tryHTTP()
            tryTCP()
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        connections.forEach { $0.cancel() }; connections = []
        listeners.forEach { $0.cancel() }; listeners = []
        if let ssid { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
        ssid = nil
    }

    private func frame(_ jpeg: Data, from source: String) {
        if !found { found = true; Log.line("livewifi: IMAGES depuis \(source) (\(jpeg.count) o)") }
        glasses.showLive(jpeg, native: true)
    }

    // MARK: HTTP (MJPEG or single JPEG)

    private func tryHTTP() {
        for path in Self.httpPaths {
            guard let url = URL(string: path, relativeTo: Proto.mediaBase) else { continue }
            var cutter = JPEGCutter()
            let task = http.dataTask(with: url) { data, response, error in
                let r = response as? HTTPURLResponse
                let head = data.map { Log.hex($0.prefix(32)) } ?? ""
                Task { @MainActor in
                    Log.line("livewifi http /\(path) \(r?.statusCode ?? 0) \(r?.value(forHTTPHeaderField: "Content-Type") ?? "") \(data?.count ?? 0)o \(head) \(error?.localizedDescription ?? "")")
                    if let data { cutter.feed(data).forEach { self.frame($0, from: "http /\(path)") } }
                }
            }
            tasks.append(task)
            task.resume()
        }
    }

    // MARK: Raw TCP: connect, send an HTTP GET (harmless if it's not HTTP), read whatever comes

    private func tryTCP() {
        for port in Self.tcpPorts {
            let c = NWConnection(host: "192.168.169.1", port: .init(integerLiteral: port), using: .tcp)
            connections.append(c)
            var cutter = JPEGCutter()
            var total = 0
            c.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        Log.line("livewifi tcp \(port) OPEN")
                        if port == 554 || port == 8554 { self.rtspProbe(c, port: port) }
                        else { c.send(content: Data("GET / HTTP/1.1\r\nHost: 192.168.169.1\r\n\r\n".utf8), completion: .idempotent) }
                        self.read(c) { data in
                            if port == 554 || port == 8554, total < 20000 {
                                Log.line("livewifi rtsp \(port) « \(String(decoding: data.prefix(1500), as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | ")) »")
                            } else if total == 0 { Log.line("livewifi tcp \(port) reçoit \(Log.hex(data.prefix(48)))") }
                            total += data.count
                            cutter.feed(data).forEach { self.frame($0, from: "tcp \(port)") }
                        }
                    case .failed, .waiting: c.cancel()
                    default: break
                    }
                }
            }
            c.start(queue: .main)
        }
    }

    /// Port 554 answered on the real glasses (2026-11-08): ask RTSP what it serves on the usual paths.
    /// The replies (status line, SDP with codec) go to the journal; decoding comes once we know them.
    private func rtspProbe(_ c: NWConnection, port: UInt16) {
        let paths = ["", "live", "stream", "av0_0", "11", "h264", "live/ch00_0", "cam/realmonitor", "video", "media"]
        var seq = 1
        func req(_ method: String, _ path: String, _ extra: String = "") -> Data {
            defer { seq += 1 }
            return Data("\(method) rtsp://192.168.169.1:\(port)/\(path) RTSP/1.0\r\nCSeq: \(seq)\r\nUser-Agent: Iris\r\n\(extra)\r\n".utf8)
        }
        c.send(content: req("OPTIONS", ""), completion: .idempotent)
        for (i, path) in paths.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i + 1)) {
                c.send(content: req("DESCRIBE", path, "Accept: application/sdp\r\n"), completion: .idempotent)
            }
        }
    }

    private func read(_ c: NWConnection, _ got: @escaping (Data) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            Task { @MainActor in
                if let data, !data.isEmpty { got(data) }
                if !done, error == nil { self.read(c, got) }
            }
        }
    }

    // MARK: UDP: many cheap cameras push frames to the client once it's on their network

    private func listenUDP() {
        for port in Self.udpPorts {
            guard let l = try? NWListener(using: .udp, on: .init(integerLiteral: port)) else { continue }
            var cutter = JPEGCutter()
            var count = 0
            l.newConnectionHandler = { c in
                c.start(queue: .main)
                Task { @MainActor in
                    self.connections.append(c)
                    self.readUDP(c) { data in
                        count += 1
                        if count <= 3 { Log.line("livewifi udp \(port) \(data.count)o \(Log.hex(data.prefix(32)))") }
                        cutter.feed(data).forEach { self.frame($0, from: "udp \(port)") }
                    }
                }
            }
            l.start(queue: .main)
            listeners.append(l)
            // Also knock: some firmwares only start sending after any packet from the client.
            let knock = NWConnection(host: "192.168.169.1", port: .init(integerLiteral: port), using: .udp)
            knock.start(queue: .main)
            knock.send(content: Data([0x00]), completion: .contentProcessed { _ in knock.cancel() })
        }
    }

    private func readUDP(_ c: NWConnection, _ got: @escaping (Data) -> Void) {
        c.receiveMessage { data, _, _, error in
            Task { @MainActor in
                if let data, !data.isEmpty { got(data) }
                if error == nil { self.readUDP(c, got) }
            }
        }
    }
}
