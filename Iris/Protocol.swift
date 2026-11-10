import Foundation

/// Wire format of the L801 glasses (JieLi chip).
/// Verified against real frames captured on 2026-11-07.
///
///   Phone → glasses, AA13:  AB 55 | LEN u16 BE | CMD | payload | CK
///   Glasses → phone, AA14:  AC 55 | same layout
///   LEN = payload + 2 (CMD and CK). CK = (CMD + Σ payload) & 0xFF.
///
///   Image stream, AA15:     52 58 | LEN u16 BE | CMD | payload | CK | 58 52
///   CMD 97 = start, 98 = chunk (first 4 payload bytes are an offset), 99 = end.
enum Proto {
    static func frame(_ cmd: UInt8, _ payload: [UInt8] = [0]) -> Data {
        let len = payload.count + 2
        let ck = UInt8((Int(cmd) + payload.reduce(0) { $0 + Int($1) }) & 0xFF)
        return Data([0xAB, 0x55, UInt8(len >> 8), UInt8(len & 0xFF), cmd] + payload + [ck])
    }

    static func setTime(_ date: Date = Date()) -> Data {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return frame(0x59, [c.year! - 2000, c.month!, c.day!, c.hour!, c.minute!, c.second!].map(UInt8.init))
    }

    static let status = frame(0x48)
    static let capabilities = frame(0x95)
    static let sync = frame(0x45)
    static let customer = Data([0xAB, 0x55, 0x00, 0x02, 0x64, 0x64])
    static let battery = frame(0x17)
    /// 0x16 GET_CAPACITY: the glasses reply with their storage.
    static let storage = frame(0x16)
    static let photo = frame(0x22, [0x30])
    static let aiPhoto = frame(0x22, [0x31])
    static let videoStart = frame(0x23)
    static let videoStop = frame(0x24)
    /// Firmware live (capability bit 0). Verified 2026-11-07 from the Mac: '1' → ack 0x67 01 then
    /// 0x25 hotspot SSID, so the video goes over Wi-Fi; '0' → ack 0x67 00. Raw 0x01 is refused (ack 00).
    static func live(_ on: Bool) -> Data { frame(0x67, [on ? 0x31 : 0x30]) }
    /// Turns on the glasses' hotspot (0x30 = AP mode). They answer 0x25 with the SSID.
    static let wifiOn = frame(0x39, [0x30])
    /// "All files downloaded": the glasses switch their hotspot off.
    static let wifiDone = frame(0x44, [0x30, 0x00])
    /// Hardcoded in the vendor app, never sent by the glasses.
    static let wifiPassword = "12345678"
    static let mediaBase = URL(string: "http://192.168.169.1/")!

    /// 0x25 reply: the whole payload is the SSID (vendor app ignores anything under 5 chars).
    static func wifiSSID(_ m: Message) -> String? {
        guard m.cmd == 0x25, let ssid = String(bytes: m.payload, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespaces)), ssid.count >= 5 else { return nil }
        return ssid
    }

    /// Samples per Opus packet, from its TOC byte (RFC 6716 §3.1). Code 3 packets
    /// signal their count inside; the glasses send single 20 ms frames, so we assume 1.
    static func opusFrames(toc: UInt8, rate: Int = 16000) -> Int {
        let config = Int(toc >> 3)
        let ms: Double
        switch config {
        case 0...11: ms = [10, 20, 40, 60][config % 4]
        case 12...15: ms = [10, 20][config % 2]
        default: ms = [2.5, 5, 10, 20][config % 4]
        }
        return Int(ms * Double(rate) / 1000) * [1, 2, 2, 1][Int(toc & 3)]
    }

    struct MediaFile: Decodable, Equatable {
        let name: String
        let size: Int
        var isVideo: Bool { ["mp4", "mov", "avi"].contains((name as NSString).pathExtension.lowercased()) }
    }

    /// GET app/getfilelist → {"info":[{"folder":…,"files":[{"name","size","type","createtimestr"}]}]}
    static func fileList(_ json: Data) throws -> [MediaFile] {
        struct Folder: Decodable { let files: [MediaFile]? }
        struct Reply: Decodable { let info: [Folder]? }
        return try JSONDecoder().decode(Reply.self, from: json).info?.flatMap { $0.files ?? [] } ?? []
    }

    struct Message: Equatable { let cmd: UInt8; let payload: [UInt8] }

    /// One AA14 notification → its messages. Checksum-failing frames are dropped.
    static func parse(_ data: Data) -> [Message] {
        let b = [UInt8](data)
        var out: [Message] = [], i = 0
        while i + 5 <= b.count, b[i] == 0xAC, b[i + 1] == 0x55 {
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let end = i + 4 + len
            guard len >= 2, end <= b.count else { break }
            let cmd = b[i + 4], payload = Array(b[(i + 5)..<(end - 1)])
            if UInt8((Int(cmd) + payload.reduce(0) { $0 + Int($1) }) & 0xFF) == b[end - 1] {
                out.append(Message(cmd: cmd, payload: payload))
            }
            i = end
        }
        return out
    }

    enum ImageEvent: Equatable { case start, chunk(Data), end, other(cmd: UInt8, Data) }

    /// One complete AA15 frame → image event.
    static func parseImage(_ data: Data) -> ImageEvent? {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0x52, b[1] == 0x58 else { return nil }
        switch b[4] {
        case 0x97: return .start
        case 0x99: return .end
        case 0x98:
            let body = b[5..<(b.count - 3)]
            return .chunk(body.count > 4 ? Data(body.dropFirst(4)) : Data())
        default: return .other(cmd: b[4], data)
        }
    }

    /// AA15 frames are 508 bytes; below MTU 512 (typical on iPhone) one frame spans several
    /// notifications. Feed every notification, get back each completed frame's event.
    struct ImageStream {
        private var buffer = [UInt8]()

        mutating func feed(_ data: Data) -> [ImageEvent] {
            buffer += data
            var out: [ImageEvent] = []
            while true {
                // Resync on the 52 58 magic if a notification was lost.
                guard let start = buffer.indices.first(where: { $0 + 1 < buffer.count && buffer[$0] == 0x52 && buffer[$0 + 1] == 0x58 }) else {
                    buffer.removeAll(keepingCapacity: true); break
                }
                buffer.removeFirst(start)
                guard buffer.count >= 4 else { break }
                let total = (Int(buffer[2]) << 8 | Int(buffer[3])) + 6 // magic, LEN, LEN bytes, 58 52
                guard buffer.count >= total else { break }
                if let event = parseImage(Data(buffer[0..<total])) { out.append(event) }
                buffer.removeFirst(total)
            }
            return out
        }
    }

    /// 0x53 battery report: [charging, level]. 0x17 reply: BCD-ish digits + charging flag.
    static func battery(_ m: Message) -> (level: Int, charging: Bool)? {
        switch m.cmd {
        case 0x53 where m.payload.count >= 2: return (Int(m.payload[1]), m.payload[0] == 1)
        case 0x17 where m.payload.count >= 3: return (Int(m.payload[0] & 15) * 10 + Int(m.payload[1] & 15), m.payload[2] == 1)
        default: return nil
        }
    }
}

/// Pulls complete JPEGs out of any byte stream (MJPEG multipart, raw TCP, concatenated UDP payloads).
struct JPEGCutter {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while let start = buffer.firstRange(of: Data([0xFF, 0xD8])) {
            guard let end = buffer[start.upperBound...].firstRange(of: Data([0xFF, 0xD9])) else {
                buffer = Data(buffer[start.lowerBound...])
                return out
            }
            out.append(Data(buffer[start.lowerBound..<end.upperBound]))
            buffer = Data(buffer[end.upperBound...])
        }
        if buffer.count > 1 { buffer = Data(buffer.suffix(1)) }  // keep a possible lone FF
        if buffer.count > 4_000_000 { buffer = Data() }
        return out
    }
}
