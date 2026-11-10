import AVFoundation
import Speech
import CoreLocation
import UIKit

/// `devicectl … process launch com.adrbn.iris -- -selftest`: checks the on-phone pieces that
/// don't need the glasses and writes the results to the journal (Documents/iris-log.txt).
enum SelfTest {
    @MainActor
    static func run() async {
        Log.line("selftest: apple \(Brain.appleStatus)")
        do {
            let reply = try await Brain.text("Réponds juste : bonjour.", apple: true, client: AIClient(baseURL: "", model: "", apiKey: "", prompt: ""))
            Log.line("selftest: apple texte OK « \(reply.prefix(60)) »")
        } catch { Log.line("selftest: apple texte ÉCHEC \(error)") }

        let card = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            ("PASSEPORT\nRépublique française" as NSString).draw(at: CGPoint(x: 40, y: 120),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black])
        }
        let (labels, text) = Memory.tags(card)
        Log.line("selftest: vision labels \(labels.prefix(4)) texte « \(text) »")

        do {
            let places = try await Guide.nearby(CLLocation(latitude: 48.8584, longitude: 2.2945))
            Log.line("selftest: wikipédia \(places.first?.title ?? "rien") à \(places.first?.meters ?? -1) m")
        } catch { Log.line("selftest: wikipédia ÉCHEC \(error)") }

        do {
            let answer = try await Brain.answer(question: "Qu'est-ce que je tiens ?", jpeg: card, apple: true,
                                                client: AIClient(baseURL: "", model: "", apiKey: "", prompt: "Réponds en une phrase."))
            Log.line("selftest: jarvis local « \(answer.prefix(120)) »")
        } catch { Log.line("selftest: jarvis local ÉCHEC \(error)") }
        Log.line("selftest: voix \(AVSpeechSynthesisVoice.best()?.name ?? "?") qualité \(AVSpeechSynthesisVoice.best()?.quality.rawValue ?? 0) ; installées fr : \(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("fr") }.map { "\($0.name)(\($0.quality.rawValue))" })")
        await language()
        Log.line("selftest: fin")
    }

    /// Synthetic Italian sentence → file → each language model in turn: Italian must win.
    @MainActor
    private static func language() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "selftest-it.caf")
        try? FileManager.default.removeItem(at: url)
        let u = AVSpeechUtterance(string: "Buongiorno, vorrei un biglietto per la stazione centrale di Roma, per favore.")
        u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        let synth = AVSpeechSynthesizer()
        var file: AVAudioFile?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            synth.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { if !finished { finished = true; done.resume() }; return }
                if file == nil { file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
                try? file?.write(from: pcm)
            }
        }
        file = nil
        for lang in ["it", "en", "es"] {
            let regions = ["it": "it-IT", "en": "en-US", "es": "es-ES"]
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: regions[lang]!)) else { continue }
            let (score, text) = await Translator.score(url, r)
            Log.line("selftest: langue \(lang) \(String(format: "%.2f", score)) « \(text.prefix(50)) » ondevice=\(r.supportsOnDeviceRecognition)")
        }
    }
}
