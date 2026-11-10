import SwiftUI

/// Every setting the firmware exposes over BLE, read back from the glasses after each change.
/// Most 1-byte settings travel as ASCII digits ('2' = 0x32), like the vendor app sends them.
struct GlassesSettings: View {
    @ObservedObject var glasses: Glasses
    @State private var rawCmd = ""
    @State private var rawPayload = "00"

    var body: some View {
        Form {
            Section("Lunettes") {
                row("Firmware", text(0x55))
                row("Modèle", text(0x64))
                row("Capacités (0x95)", hex(0x95))
                row("Volume (0x69)", hex(0x69))
                row("Stockage", storage)
                row("Portées", glasses.worn.map { $0 ? "oui" : "non" } ?? "inconnu")
            }

            Section {
                Picker("Durée max d'une vidéo", selection: binding(seconds, { glasses.set(0x02, [UInt8($0 >> 8), UInt8($0 & 0xFF)]) })) {
                    ForEach([30, 60, 120, 180, 300, 600], id: \.self) { Text($0 < 60 ? "\($0) s" : "\($0 / 60) min").tag($0) }
                }
                Toggle("Orientation caméra (0x61)", isOn: flag(0x61))
            } header: { Text("Caméra") }

            Section {
                Picker("Luminosité", selection: binding(digit(0x01), { glasses.set(0x01, [UInt8(0x30 + $0)]) })) {
                    ForEach(0...5, id: \.self) { Text("\($0)").tag($0) }
                }
            } header: { Text("LED") } footer: {
                Text("Seule commande LED du firmware : ni couleur ni clignotement. Plage exacte inconnue (réglée sur 2 à la livraison).")
            }

            Section {
                Toggle("Détection du port", isOn: flag(0x04))
                Toggle("Commande vocale (0x06)", isOn: flag(0x06))
                Toggle("Mot de réveil", isOn: voiceMask(bit: 1))
                Toggle("Assistant au toucher", isOn: voiceMask(bit: 2))
            } header: { Text("Capteurs et voix") } footer: {
                Text("Mot de réveil et toucher : lus par 0x71, écrits par 0x72. Tes lunettes ne déclarent pas ce réglage, il peut être ignoré.")
            }

            Section {
                gesture("Glissé avant", 0x07)
                gesture("Glissé arrière", 0x08)
                gesture("Tap", 0x09)
                gesture("Double tap", 0x10)
                gesture("Triple tap", 0x11)
                Button("Gestes d'usine") { glasses.set(0x43, [0]) }
            } header: { Text("Gestes") } footer: {
                Text("Le firmware attend un numéro de fonction ; leur sens n'est pas documenté. Change un chiffre, fais le geste, regarde ce qui se passe.")
            }

            Section {
                HStack {
                    TextField("CMD hex", text: $rawCmd).frame(width: 80)
                    TextField("payload hex", text: $rawPayload)
                    Button("Envoyer") { sendRaw() }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                ForEach(glasses.journal.prefix(40), id: \.self) { Text($0).font(.caption.monospaced()) }
            } header: { Text("Console brute") } footer: {
                Text("Envoie n'importe quelle commande. 0x14 = remise à zéro d'usine : refusée ici.")
            }
        }
        .navigationTitle("Réglages des lunettes")
        .refreshable { glasses.readSettings() }
        .onAppear { glasses.readSettings() }
    }

    private var seconds: Int {
        guard let p = glasses.settings[0x02], p.count >= 2 else { return 180 }
        return Int(p[0]) << 8 | Int(p[1])
    }

    private func digit(_ cmd: UInt8) -> Int {
        guard let b = glasses.settings[cmd]?.first, (0x30...0x39).contains(b) else { return 0 }
        return Int(b - 0x30)
    }

    private func flag(_ cmd: UInt8) -> Binding<Bool> {
        Binding(get: { digit(cmd) == 1 }, set: { glasses.set(cmd, [$0 ? 0x31 : 0x30]) })
    }

    /// 0x71/0x72 is a *disable* mask: bit set = feature off.
    private func voiceMask(bit: UInt8) -> Binding<Bool> {
        let mask = glasses.settings[0x71]?.first ?? 0
        return Binding(get: { mask & bit == 0 }, set: { glasses.set(0x72, [$0 ? mask & ~bit : mask | bit]) })
    }

    private func binding(_ value: Int, _ write: @escaping (Int) -> Void) -> Binding<Int> {
        Binding(get: { value }, set: write)
    }

    private func gesture(_ label: String, _ cmd: UInt8) -> some View {
        Stepper("\(label) : \(digit(cmd))", value: binding(digit(cmd), { glasses.set(cmd, [UInt8(0x30 + $0)]) }), in: 0...9)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "…" : value)
    }

    private func hex(_ cmd: UInt8) -> String {
        (glasses.settings[cmd] ?? []).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func text(_ cmd: UInt8) -> String {
        let bytes = (glasses.settings[cmd] ?? []).filter { (0x20...0x7E).contains($0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 0x16 reply layout is unconfirmed: show a best guess (two big-endian uint32 = total/free, in MB
    /// if they look like KB) plus the raw bytes, so the real format is visible on the glasses.
    private var storage: String {
        let b = glasses.settings[0x16] ?? []
        guard b.count >= 8 else { return hex(0x16).isEmpty ? "—" : hex(0x16) }
        func u32(_ i: Int) -> UInt64 { b[i...(i+3)].reduce(0) { $0 << 8 | UInt64($1) } }
        let total = u32(0), free = u32(4)
        func mb(_ v: UInt64) -> String { v > 1 << 20 ? String(format: "%.1f Go", Double(v) / 1073741824.0) : String(format: "%.0f Mo", Double(v) / 1048576.0) }
        return "\(mb(free)) libres / \(mb(total))  (\(hex(0x16)))"
    }

    private func sendRaw() {
        guard let cmd = UInt8(rawCmd.replacingOccurrences(of: "0x", with: ""), radix: 16), cmd != 0x14 else { return }
        let clean = rawPayload.replacingOccurrences(of: " ", with: "")
        let payload = stride(from: 0, to: clean.count - 1, by: 2).compactMap {
            UInt8(clean.dropFirst($0).prefix(2), radix: 16)
        }
        glasses.sendRaw(cmd, payload.isEmpty ? [0] : payload)
    }
}
