import AVFoundation
import Speech

/// Glasses mic → text, entirely on the phone: Opus packets (BLE 0x46, 40 bytes each, 16 kHz mono)
/// → PCM via AudioToolbox → Apple speech recognition (on-device when the language pack is there).
/// The last utterance is kept as Documents/derniere-voix.wav for debugging.
@MainActor
final class Ears {
    /// Live partial transcript, for the UI.
    var onPartial: ((String) -> Void)?

    private let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private var converter: AVAudioConverter?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?
    /// Safety: if the glasses stream keeps coming with no new words, stop so the mic (and battery) rest.
    var onSilence: (() -> Void)?
    private var pending = Data()
    private var recording: AVAudioFile?
    private var done: ((String) -> Void)?
    private var transcript = ""
    /// True once we've asked the recognizer to stop (voice end or silence): a final callback then
    /// delivers instead of restarting.
    private var ending = false
    private static let packetSize = 40
    static let lastVoice = URL.documentsDirectory.appending(path: "derniere-voix.wav")

    init() {
        SFSpeechRecognizer.requestAuthorization { status in Log.line("speech auth \(status.rawValue)") }
    }

    func start(done: @escaping (String) -> Void) {
        task?.cancel()
        self.done = done
        transcript = ""
        pending = Data()
        converter = nil
        ending = false
        recording = try? AVAudioFile(forWriting: Self.lastVoice, settings: pcm.settings)
        resetSilence() // backstop: always end within 6 s of true silence, even if no audio ever arrives
        startTask()
    }

    /// (Re)creates the recognizer task, keeping the current transcript and converter. Called on start and
    /// again when the recognizer bails early ("No speech detected") while the glasses are still streaming.
    private func startTask() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        self.request = request
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true || error != nil
            if let error { Log.line("speech error \(error.localizedDescription)") }
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let text, !text.isEmpty { self.transcript = text; self.onPartial?(text); self.resetSilence() }
                guard final else { return }
                // A fragment can make the recognizer quit in ~30 ms. If we weren't told to stop and have
                // nothing yet, start a fresh recognizer and keep listening instead of saying "rien entendu".
                if error != nil, !self.ending, self.transcript.isEmpty {
                    Log.line("ears: reconnaissance relancée")
                    self.request = nil // ignore late callbacks from the task we're dropping
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self, !self.ending, self.done != nil else { return }
                        self.startTask()
                    }
                } else {
                    self.deliver()
                }
            }
        }
        Log.line("ears start, on-device \(request.requiresOnDeviceRecognition)")
    }

    /// The iPhone's own mic: the glasses ignore 0x57 (it only retries a voice transfer they started,
    /// 08/11), so the home button listens here instead. Same recognizer, same silence rules.
    private let engine = AVAudioEngine()
    func startPhone(done: @escaping (String) -> Void) {
        start(done: done)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                Task { @MainActor in self?.request?.append(buffer) }
            }
            try engine.start()
            Log.line("ears: micro de l'iPhone")
        } catch {
            Log.line("ears: micro de l'iPhone en échec (\(error.localizedDescription))")
            finish()
        }
    }

    func feed(_ data: Data) {
        guard request != nil else { return }
        if silence == nil { resetSilence() }
        pending += data
        while pending.count >= Self.packetSize {
            decode(pending.prefix(Self.packetSize))
            pending.removeFirst(Self.packetSize)
        }
    }

    private func resetSilence() {
        silence?.invalidate()
        // 6 s to start talking, then 1.6 s of quiet after the last word ends the question.
        silence = Timer.scheduledTimer(withTimeInterval: transcript.isEmpty ? 6 : 1.6, repeats: false) { [weak self] _ in
            Task { @MainActor in guard let self, self.done != nil, !self.ending else { return }; Log.line("ears: silence, arrêt"); self.onSilence?(); self.finish() }
        }
    }

    func finish() {
        guard done != nil, !ending else { return }
        ending = true
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        silence?.invalidate(); silence = nil
        request?.endAudio()
        recording = nil
        // Apple sometimes never sends isFinal for buffer requests: don't wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.deliver() }
    }

    private func deliver() {
        guard let done else { return }
        self.done = nil
        request = nil
        task = nil
        Log.line("ears heard \"\(transcript)\"")
        done(transcript)
    }

    private func decode(_ packet: Data) {
        if converter == nil {
            var description = AudioStreamBasicDescription(
                mSampleRate: 16000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(Proto.opusFrames(toc: packet[packet.startIndex])), mBytesPerFrame: 0,
                mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
            converter = AVAudioFormat(streamDescription: &description).flatMap { AVAudioConverter(from: $0, to: pcm) }
            Log.line("opus toc \(Log.hex(packet.prefix(1))) frames \(description.mFramesPerPacket) converter \(converter != nil)")
        }
        guard let converter else { return }
        let input = AVAudioCompressedBuffer(format: converter.inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                     mDataByteSize: UInt32(packet.count))
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)
        guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1920) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        if let error { Log.line("opus decode \(error.code)"); return }
        guard output.frameLength > 0 else { return }
        request?.append(output)
        try? recording?.write(from: output)
    }
}
