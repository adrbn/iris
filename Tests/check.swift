import CoreLocation
// Self-check of Protocol.swift against frames captured from the real glasses (2026-11-07).
// Run: ./scripts/check.sh
import Foundation

func bytes(_ hex: String) -> Data {
    Data(stride(from: 0, to: hex.count, by: 2).map { i in
        UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
    })
}

@main enum Check {
    static func main() {
        // Commands the vendor app sends, byte for byte.
        assert(Proto.aiPhoto == bytes("ab550003223153"))
        assert(Proto.battery == bytes("ab550003170017"))
        assert(Proto.setTime(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 19, minute: 48, second: 0))!)
               == bytes("ab550008591a0b07133000c8"))

        // Battery push: 76 %, not charging. And the 0x17 reply: "75", not charging.
        let push = Proto.parse(bytes("ac550004530 04c9f".replacingOccurrences(of: " ", with: "")))
        assert(push == [.init(cmd: 0x53, payload: [0x00, 0x4c])])
        assert(Proto.battery(push[0])! == (76, false))
        assert(Proto.battery(Proto.parse(bytes("ac5500051737350083"))[0])! == (75, false))

        // Bad checksum is dropped; two frames in one notification are both read.
        assert(Proto.parse(bytes("ac550004530 04c9e".replacingOccurrences(of: " ", with: ""))).isEmpty)
        assert(Proto.parse(bytes("ac550003220123ac55000442000143")).map(\.cmd) == [0x22, 0x42])

        // Wi-Fi: hotspot on, done, SSID reply, file list.
        assert(Proto.wifiOn == bytes("ab550003393069"))
        assert(Proto.wifiDone == bytes("ab55000444300074"))
        assert(Proto.wifiSSID(.init(cmd: 0x25, payload: Array("L801-A1B2".utf8))) == "L801-A1B2")
        assert(Proto.wifiSSID(.init(cmd: 0x25, payload: Array("ab".utf8))) == nil)
        let list = try! Proto.fileList(Data(#"{"result":0,"info":[{"folder":"DCIM","count":2,"files":[{"name":"/DCIM/V1.mp4","size":9,"type":2,"createtimestr":"1762540000"},{"name":"P1.jpg","size":3,"type":1,"createtimestr":"1"}]}]}"#.utf8))
        assert(list.map(\.name) == ["/DCIM/V1.mp4", "P1.jpg"] && list.map(\.isVideo) == [true, false])

        // Opus TOC → samples at 16 kHz: SILK WB 20 ms, hybrid 20 ms, CELT 20 ms, SILK 60 ms, 2 frames.
        assert([0x48, 0x78, 0xF8, 0x18, 0x49].map { Proto.opusFrames(toc: $0) } == [320, 320, 320, 960, 640])

        // Image stream: start, a chunk keeps the bytes after the 4-byte offset, end.
        assert(Proto.parseImage(bytes("525800079700003184024e5852")) == .start)
        assert(Proto.parseImage(bytes("5258000a9800002dfcffd8ffdbaa5852")) == .chunk(bytes("ffd8ffdb")))
        assert(Proto.parseImage(bytes("525800039900995852")) == .end)
        // A 508-byte frame split over three notifications (iPhone MTU 185), then end, in one stream.
        let payload = (0..<496).map { UInt8($0 & 0xFF) }
        let len = 1 + 4 + 496 + 1
        let chunk = Data([0x52, 0x58, UInt8(len >> 8), UInt8(len & 0xFF), 0x98, 0, 0, 0x2d, 0xfc] + payload + [0xaa, 0x58, 0x52])
        var stream = Proto.ImageStream()
        assert(stream.feed(bytes("525800079700003184024e5852")) == [.start])
        assert(stream.feed(chunk.prefix(182)).isEmpty)
        assert(stream.feed(chunk.dropFirst(182).prefix(182)).isEmpty)
        assert(stream.feed(chunk.dropFirst(364) + bytes("525800039900995852")) == [.chunk(Data(payload)), .end])
        var cutter = JPEGCutter()
        let jpegA = Data([0xFF, 0xD8, 1, 2, 0xFF, 0xD9]), jpegB = Data([0xFF, 0xD8, 3, 0xFF, 0xD9])
        assert(cutter.feed(Data("--iris\r\n".utf8) + jpegA.prefix(3)).isEmpty)
        assert(cutter.feed(jpegA.dropFirst(3) + Data([9, 9]) + jpegB + Data([0xFF])) == [jpegA, jpegB])
        assert(cutter.feed(Data([0xD8, 7, 0xFF, 0xD9])) == [Data([0xFF, 0xD8, 7, 0xFF, 0xD9])])
        let wiki = Data(#"{"query":{"pages":[{"title":"Loin","extract":"b","coordinates":[{"lat":48.87,"lon":2.29}]},{"title":"Tour Eiffel","extract":"a","coordinates":[{"lat":48.8584,"lon":2.2945}]},{"title":"Sans coord"}]}}"#.utf8)
        let places = try! Guide.parse(wiki, from: CLLocation(latitude: 48.8583, longitude: 2.2945))
        assert(places.map(\.title) == ["Tour Eiffel", "Loin", "Sans coord"] && places[0].meters! < 20 && places[2].meters == nil)
        assert(try! Guide.parse(Data("{}".utf8), from: CLLocation(latitude: 0, longitude: 0)).isEmpty)
        for q in ["C'est quoi ça ?", "Lis-moi ce panneau", "traduis le menu", "Qu’est-ce que c’est", "c'est qui lui"] { assert(Intent.needsImage(q), q) }
        for q in ["Quelle heure est-il à Tokyo ?", "Raconte-moi une blague"] { assert(!Intent.needsImage(q), q) }
        assert(!Intent.needsImage("comment cava")) // "ça" only as a word
        print("ok")
    }
}
