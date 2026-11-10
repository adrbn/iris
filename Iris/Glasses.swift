import CoreBluetooth
import Foundation

/// BLE link to the L801 glasses. Connects to the first device whose name starts with "L801",
/// replays the vendor app's init sequence, then turns AI-photo streams into JPEGs.
@MainActor
final class Glasses: NSObject, ObservableObject {
    enum State: String { case off = "Bluetooth coupé", searching = "Recherche…", connecting = "Connexion…", ready = "Connectées" }

    @Published private(set) var state: State = .off
    @Published private(set) var name = ""
    @Published private(set) var battery: Int?
    @Published private(set) var charging = false
    @Published private(set) var lastEvent = ""
    /// From the 0x45 status report: [photo, audio, video, …] flags.
    @Published private(set) var recordingSince: Date?
    /// Live view: latest frame, and how it is produced.
    @Published private(set) var liveJPEG: Data?
    @Published private(set) var liveFrames = 0
    @Published private(set) var liveBurst = false
    private(set) var live = false
    /// Live turned off: Media closes the hotspot.
    var onLiveOff: (() -> Void)?
    /// Settings as last reported by the glasses (reply to 0x48 status, 0x71, 0x55…), keyed by command.
    @Published private(set) var settings: [UInt8: [UInt8]] = [:]
    /// From 0x45 index 8. nil until the glasses report it.
    @Published private(set) var worn: Bool?
    /// Every frame the glasses send, newest first, for the raw console.
    @Published private(set) var journal: [String] = []
    /// 0x07…0x11 are both setting echoes (in the 0x48 reply) and gesture events: inside this window they're settings.
    private var statusUntil = Date.distantPast

    /// Called with each JPEG the glasses send (AI photos, 320×180).
    var onPhoto: ((Data) -> Void)?
    /// Voice from the glasses' mic: start (0x97, wake word / button / startListening), Opus packets (0x46), end (0x99).
    var onVoiceStart: (() -> Void)?
    var onVoiceData: ((Data) -> Void)?
    var onVoiceEnd: (() -> Void)?
    @Published private(set) var listening = false
    /// Called with the hotspot SSID once the glasses turned their Wi-Fi on.
    var onWifi: ((String) -> Void)?
    /// Gesture from the glasses: front, back, tap, double, triple, nod, shake.
    var onGesture: ((String) -> Void)?

    private static let service = CBUUID(string: "AA12")
    private static let write = CBUUID(string: "AA13")
    private static let events = CBUUID(string: "AA14")
    private static let images = CBUUID(string: "AA15")
    private static let savedID = "glassesID"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var jpeg = Data()
    private var imageStream = Proto.ImageStream()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "iris.glasses"])
    }

    /// In live (hotspot) mode the camera belongs to the Wi-Fi stream and photo requests are refused
    /// with a beep: leave live first.
    func takeAIPhoto(retry: Bool = true) {
        lastEvent = "Photo demandée…"
        let asked = Date()
        if live { setLive(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (live ? 1.5 : 0)) { [weak self] in self?.send(Proto.aiPhoto) }
        // Verified 2026-11-08: with the hotspot left on, 0x22 gets no reply at all, only a beep.
        // No image start within 4 s → shut the hotspot (0x67 '0' + 0x44) and try once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, retry, self.photoStart < asked else { return }
            Log.line("photo: pas de réponse, je coupe le hotspot et je réessaie")
            self.resetHotspot()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.takeAIPhoto(retry: false) }
        }
    }

    private var photoStart = Date.distantPast

    /// 0x67 '0' alone isn't enough once the hotspot is up (answered 67 01 + SSID): 0x44 closes it.
    func resetHotspot() {
        send(Proto.live(false))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.send(Proto.wifiDone) }
    }
    func takePhoto() { send(Proto.photo) }
    func toggleVideo() { send(recordingSince == nil ? Proto.videoStart : Proto.videoStop) }
    func refreshBattery() { send(Proto.battery) }
    func wifiOn() { send(Proto.wifiOn) }
    /// 0x57 asks the glasses to open their mic; they confirm with 0x97. No answer in 3 s → say so.
    func startListening() {
        Log.line("bouton IA → 0x57 (état \(state.rawValue))")
        send(Proto.frame(0x57))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.listening else { return }
            Log.line("bouton IA : pas de 0x97 en 3 s")
            self.lastEvent = "Les lunettes n'ont pas ouvert le micro, réessaie"
        }
    }
    /// The glasses only echo 0x56, never 0x99: clear the state here or the button stays on "écoute" (08/11).
    func stopListening() { send(Proto.frame(0x56)); listening = false }

    /// Asks the firmware for its native live stream (0x67). If no frame comes within 6 s,
    /// falls back to a burst of AI photos over BLE (~0.35 fps, capture takes ~2.3 s each).
    func setLive(_ on: Bool, force: Bool = false) {
        guard on != live || force else { return }
        live = on
        liveBurst = false
        Log.line("live \(on)")
        send(Proto.live(on))
        guard on else { onLiveOff?(); return }
        liveFrames = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.live, self.liveFrames == 0 else { return }
            Log.line("live: no native frame, BLE photo burst")
            self.liveBurst = true
            self.send(Proto.aiPhoto)
        }
    }
    func wifiDone() { send(Proto.wifiDone) }

    /// A live frame from any source. Native (Wi-Fi) frames stop the BLE photo burst.
    func showLive(_ jpeg: Data, native: Bool) {
        guard live else { return }
        if native { liveBurst = false }
        liveJPEG = jpeg
        liveFrames += 1
    }

    /// Writes one setting, then re-reads the status so the screen shows what the glasses actually kept.
    func set(_ cmd: UInt8, _ payload: [UInt8]) {
        send(Proto.frame(cmd, payload))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.readSettings() }
    }

    func readSettings() {
        statusUntil = Date().addingTimeInterval(1.5)
        send(Proto.status)
        send(Proto.frame(0x71))
        send(Proto.frame(0x55))
        send(Proto.frame(0x69))
        send(Proto.storage)
    }

    /// Raw console: any command, any payload.
    func sendRaw(_ cmd: UInt8, _ payload: [UInt8]) { send(Proto.frame(cmd, payload)) }

    private func send(_ data: Data) {
        guard let peripheral, let writer else { return }
        Log.line("TX \(Log.hex(data))")
        peripheral.writeValue(data, for: writer, type: .withResponse)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        name = p.name ?? "L801"
        state = .connecting
        central.connect(p)
    }

    private func reconnectOrScan() {
        guard central.state == .poweredOn else { state = .off; return }
        if let raw = UserDefaults.standard.string(forKey: Self.savedID), let id = UUID(uuidString: raw),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known) // pending connect: completes whenever the glasses come in range
            // If they changed address or the pending connect is stuck, also look for them by name.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.state != .ready, self.central.state == .poweredOn else { return }
                Log.line("ble: pas de reconnexion directe, scan")
                self.central.scanForPeripherals(withServices: nil)
            }
        } else {
            state = .searching
            central.scanForPeripherals(withServices: nil)
        }
    }

    /// Same order and spacing as the official app, minus language and bonding.
    private func handshake() {
        let steps: [(Double, Data)] = [
            (0.2, Proto.status), (0.3, Proto.frame(0x55)), (0.35, Proto.frame(0x71)), (0.4, Proto.capabilities), (0.6, Proto.sync),
            (0.8, Proto.customer), (1.2, Proto.setTime()), (1.6, Proto.battery),
        ]
        // A previous session (or a crash) can leave the hotspot on, which blocks photos: reset it.
        if !live { DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.resetHotspot() } }
        statusUntil = Date().addingTimeInterval(2)
        for (delay, frame) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.send(frame) }
        }
    }

    private func handle(_ m: Proto.Message) {
        journal.insert(String(format: "%@  %02X  %@", Date().formatted(date: .omitted, time: .standard), m.cmd,
                              m.payload.map { String(format: "%02x", $0) }.joined(separator: " ")), at: 0)
        if journal.count > 200 { journal.removeLast() }
        let setting: Set<UInt8> = [0x01, 0x02, 0x03, 0x04, 0x06, 0x16, 0x61, 0x62, 0x55, 0x64, 0x69, 0x71, 0x95]
        let gesture: Set<UInt8> = [0x07, 0x08, 0x09, 0x10, 0x11]
        if setting.contains(m.cmd) || (gesture.contains(m.cmd) && Date() < statusUntil) {
            settings[m.cmd] = m.payload
            return
        }
        if let b = Proto.battery(m) { battery = b.level; charging = b.charging; return }
        if let ssid = Proto.wifiSSID(m) { onWifi?(ssid); return }
        if m.cmd == 0x45, m.payload.count >= 3 {
            let recording = m.payload[2] == 1
            if recording, recordingSince == nil { recordingSince = Date() }
            if !recording { recordingSince = nil }
            if m.payload.count > 8 { worn = m.payload[8] == 1 }
            if m.payload.count > 6 {
                if m.payload[5] == 1 { lastEvent = "Hochement de tête"; onGesture?("nod") }
                if m.payload[6] == 1 { lastEvent = "Secouement de tête"; onGesture?("shake") }
            }
            return
        }
        switch m.cmd {
        case 0x0A: lastEvent = "Déclencheur photo IA"; takeAIPhoto()
        case 0x07: lastEvent = "Glissé avant"; onGesture?("front")
        case 0x08: lastEvent = "Glissé arrière"; onGesture?("back")
        case 0x09: lastEvent = "Tap"; onGesture?("tap")
        case 0x10: lastEvent = "Double tap"; onGesture?("double")
        case 0x11: lastEvent = "Triple tap"; onGesture?("triple")
        case 0x97: lastEvent = "Je t'écoute…"; listening = true; onVoiceStart?()
        case 0x46: onVoiceData?(Data(m.payload))
        case 0x99, 0x49: lastEvent = "Voix : fin"; listening = false; onVoiceEnd?()
        case 0x44: lastEvent = "Wi-Fi des lunettes coupé"   // echo of Proto.wifiDone
        // Unknown frames stay in the technical journal: a hex code means nothing on the home screen.
        case 0x22, 0x23, 0x24, 0x42, 0x48, 0x59: break
        default: break
        }
    }
}

extension Glasses: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated { reconnectOrScan() }
    }

    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
                peripheral = p
                p.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi: NSNumber) {
        let advName = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard advName.hasPrefix("L801") else { return }
        MainActor.assumeIsolated {
            c.stopScan()
            if let old = peripheral, old.identifier != p.identifier { c.cancelPeripheralConnection(old) }
            Log.line("ble: trouvées par scan \(advName)")
            connect(p)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedID)
            name = p.name ?? name
            p.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            writer = nil
            state = .connecting
            c.connect(p) // iOS keeps this pending until the glasses are back
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { c.connect(p) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in p.services ?? [] where s.uuid == Self.service { p.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for ch in s.characteristics ?? [] {
                if ch.uuid == Self.write { writer = ch }
                if ch.uuid == Self.events || ch.uuid == Self.images { p.setNotifyValue(true, for: ch) }
            }
            state = .ready
            handshake()
            // Live was asked for while the glasses were away: start it now that they're here.
            if live { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.setLive(true, force: true) } }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        let uuid = ch.uuid
        MainActor.assumeIsolated {
            if uuid == Self.images {
                if live, !(data.count > 1 && data[0] == 0x52 && data[1] == 0x58) { Log.line("AA15 raw \(Log.hex(data))") }
                for event in imageStream.feed(data) {
                    switch event {
                    case .start: jpeg = Data(); photoStart = Date(); lastEvent = "Photo : réception…"
                    case .chunk(let part): jpeg.append(part)
                    case .end:
                        Log.line("AA15 image \(jpeg.count) B")
                        if live {
                            if liveBurst { showLive(jpeg, native: false); send(Proto.aiPhoto) }
                        } else {
                            lastEvent = "Photo reçue : \(jpeg.count) octets"
                            if !jpeg.isEmpty { onPhoto?(jpeg) }
                        }
                    case .other(let cmd, let frame):
                        Log.line(String(format: "AA15 cmd %02x ", cmd) + Log.hex(frame))
                    }
                }
            } else if uuid == Self.events {
                if !(data.count > 4 && data[4] == 0x46) { Log.line("AA14 \(Log.hex(data))") }
                Proto.parse(data).forEach(handle)
            }
        }
    }
}
