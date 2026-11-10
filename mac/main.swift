import CoreAudio
import AppKit
import CoreBluetooth
import Network

/// Iris Live (Mac): stays next to the glasses at home, pulls BLE photos in a loop (no Wi-Fi needed,
/// so the Mac keeps its internet) and serves them as MJPEG on the Mac's Tailscale address:
/// http://<mac-tailscale>:8081/<token>/  → viewable from anywhere on the tailnet.
let port: NWEndpoint.Port = 8081
let token: String = {
    if let t = UserDefaults.standard.string(forKey: "token") { return t }
    let t = "iris-" + String(UUID().uuidString.prefix(6)).lowercased()
    UserDefaults.standard.set(t, forKey: "token")
    return t
}()
let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/IrisLive.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try! FileHandle(forWritingTo: logURL)
func log(_ s: String) { logHandle.write(Data("\(Date().formatted(date: .omitted, time: .standard)) \(s)\n".utf8)) }

var latest = Data()
var status = "Iris Live attend l'autorisation Bluetooth sur le Mac (Réglages › Confidentialité › Bluetooth)."
var viewers: [NWConnection] = []

final class Glasses: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    var p: CBPeripheral?
    var w: CBCharacteristic?
    var stream = Proto.ImageStream()
    var jpeg = Data()
    var lastFrame = Date.distantPast
    /// Below this the firmware answers every photo request with a spoken "no battery".
    static let minBattery = 15
    var battery: Int?
    var lastBatteryAsk = Date.distantPast

    override init() {
        super.init()
        cm = CBCentralManager(delegate: self, queue: nil)
        // Watchdog: re-ask for a photo if the loop stalls, rescan if disconnected.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            if self.p?.state == .connected, Date().timeIntervalSince(self.lastFrame) > 8 { self.ask() }
            if self.p == nil || self.p?.state == .disconnected { self.scan() }
        }
    }

    func scan() {
        guard cm.state == .poweredOn, !cm.isScanning else { return }
        p = nil
        cm.scanForPeripherals(withServices: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("bluetooth state \(c.state.rawValue)")
        status = c.state == .poweredOn ? "Je cherche les lunettes (dépliées, près du Mac, app Iris de l'iPhone fermée)…" : "Bluetooth indisponible (état \(c.state.rawValue))."
        scan()
    }

    func centralManager(_ c: CBCentralManager, didDiscover per: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = per.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.hasPrefix("L801"), p == nil else { return }
        p = per; per.delegate = self; c.stopScan(); c.connect(per)
        log("connexion \(name)")
    }

    func centralManager(_ c: CBCentralManager, didConnect per: CBPeripheral) { per.discoverServices([CBUUID(string: "AA12")]) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral per: CBPeripheral, error: Error?) { log("déconnecté"); status = "Lunettes déconnectées, je les recherche…"; p = nil; scan() }
    func centralManager(_ c: CBCentralManager, didFailToConnect per: CBPeripheral, error: Error?) { p = nil; scan() }

    func peripheral(_ per: CBPeripheral, didDiscoverServices e: Error?) { per.services?.forEach { per.discoverCharacteristics(nil, for: $0) } }

    func peripheral(_ per: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == CBUUID(string: "AA13") { w = ch }
            if ch.uuid == CBUUID(string: "AA14") || ch.uuid == CBUUID(string: "AA15") { per.setNotifyValue(true, for: ch) }
        }
        log("prêt"); status = "Lunettes connectées."
        // Same handshake as the iPhone app: the firmware ignores photo requests before it.
        let steps: [(Double, Data)] = [(0.2, Proto.status), (0.4, Proto.capabilities), (0.6, Proto.sync), (0.8, Proto.customer),
                                       (1.2, Proto.setTime()), (1.6, Proto.battery)]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { per.writeValue(f, for: self.w!, type: .withResponse) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.ask() }
    }

    func ask() {
        guard let w, let p, !viewers.isEmpty || latest.isEmpty else { return } // only burn battery while someone watches
        guard let battery, battery >= Self.minBattery else {
            // Unknown or low: ask the level at most once a minute instead, never a photo.
            if Date().timeIntervalSince(lastBatteryAsk) > 60 { lastBatteryAsk = Date(); p.writeValue(Proto.battery, for: w, type: .withResponse) }
            return
        }
        log("TX photo")
        p.writeValue(Proto.aiPhoto, for: w, type: .withResponse)
    }

    func peripheral(_ per: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        guard let d = ch.value else { return }
        if ch.uuid == CBUUID(string: "AA14") {
            log("RX \(d.prefix(24).map { String(format: "%02x", $0) }.joined())")
            for m in Proto.parse(d) {
                guard let b = Proto.battery(m) else { continue }
                battery = b.level
                if b.level < Self.minBattery { status = "Batterie des lunettes à \(b.level) % : pas de photo sous \(Self.minBattery) % (sinon elles disent « no battery »)." }
            }
            return
        }
        guard ch.uuid == CBUUID(string: "AA15") else { return }
        for event in stream.feed(d) {
            switch event {
            case .start: jpeg = Data(); log("image début")
            case .chunk(let c): jpeg.append(c)
            case .end:
                latest = jpeg; lastFrame = Date(); status = ""
                push(jpeg)
                ask()
            case .other: break
            }
        }
    }
}

func push(_ jpeg: Data) {
    let part = Data("--iris\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8) + jpeg + Data("\r\n".utf8)
    for c in viewers { c.send(content: part, completion: .contentProcessed { if $0 != nil { drop(c) } }) }
}

func drop(_ c: NWConnection) { c.cancel(); viewers.removeAll { $0 === c } }

func serve() {
    let listener = try! NWListener(using: .tcp, on: port)
    listener.newConnectionHandler = { c in
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            let line = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            func reply(_ type: String, _ body: Data) {
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\r\n".utf8) + body,
                       completion: .contentProcessed { _ in c.cancel() })
            }
            switch path {
            case "/\(token)/":
                reply("text/html; charset=utf-8", Data("""
                <!doctype html><meta name=viewport content="width=device-width"><title>Iris live</title>
                <body style="margin:0;background:#000;display:grid;place-items:center;height:100vh">
                <img src="stream" style="width:100%;max-width:960px">
                <p id=s style="position:fixed;bottom:0;left:0;right:0;margin:0;padding:12px;color:#fff;font:15px -apple-system;text-align:center"></p>
                <script>setInterval(async()=>{try{s.textContent=await(await fetch('status')).text()}catch(e){s.textContent='Mac injoignable'}},2000)</script>
                """.utf8))
            case "/\(token)/frame.jpg": reply("image/jpeg", latest)
            case "/\(token)/next", "/\(token)/prev", "/\(token)/play":
                // Arrow / space key press for slides, videos, PDFs. Needs Accessibility for Iris Live.
                let code: CGKeyCode = path.hasSuffix("next") ? 124 : path.hasSuffix("prev") ? 123 : 49
                let ok = AXIsProcessTrusted()
                if ok { for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) } }
                log("télécommande \(path) \(ok ? "ok" : "refusée (Accessibilité)")")
                if ok { reply("text/plain", Data("ok".utf8)) }
                else { c.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() }) }
            case "/\(token)/status": reply("text/plain; charset=utf-8", Data(status.utf8))
            case "/\(token)/stream":
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=iris\r\nCache-Control: no-store\r\n\r\n".utf8), completion: .idempotent)
                viewers.append(c)
                log("spectateur +1 (\(viewers.count))")
                if !latest.isEmpty { push(latest) }
                glasses.ask()
            default:
                c.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }
    listener.start(queue: .main)
}

/// The glasses are also a Bluetooth headset: when they connect, macOS moves the Mac's mic and
/// speakers to them. Put both back on the MacBook's own devices.
enum AudioGuard {
    static func devices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        return (name?.takeRetainedValue() as String?) ?? ""
    }

    static func fix(_ selector: AudioObjectPropertySelector, builtIn: String) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &current)
        guard name(current).contains("L801") || name(current).contains("AI Glasses"), var mac = devices().first(where: { name($0).contains(builtIn) }) else { return }
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &mac)
        log("audio remis sur \(name(mac))")
    }

    static func start() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            fix(kAudioHardwarePropertyDefaultInputDevice, builtIn: "Micro MacBook")
            fix(kAudioHardwarePropertyDefaultOutputDevice, builtIn: "Haut-parleurs MacBook")
            fix(kAudioHardwarePropertyDefaultSystemOutputDevice, builtIn: "Haut-parleurs MacBook")
        }
    }
}

AudioGuard.start()
let glasses = Glasses()
// Puts Iris Live in System Settings › Accessibility so the remote can be switched on there.
_ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
serve()
log("Iris Live : http://<tailscale-du-mac>:\(port)/\(token)/")
try? "http://<tailscale-du-mac>:\(port)/\(token)/\n".write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/IrisLive.url"), atomically: true, encoding: .utf8)
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
