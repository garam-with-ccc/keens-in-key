import Foundation

/// Serato DJ / Engine DJ cue points ("Serato Markers2") and beat grid ("Serato BeatGrid") stored inside files.
///
/// Format reference: the community documentation of Serato's tags (Holzhaus, "serato-tags").
/// ID3 (MP3, AIFF, WAV): GEOB frames with description "Serato Markers2" / "Serato BeatGrid".
/// MP4: freeform atoms `----:com.serato.dj:markersv2` / `----:com.serato.dj:beatgrid` holding base64 text.
/// FLAC: Vorbis comments `SERATO_MARKERS_V2` / `SERATO_BEATGRID` holding base64 text.
public enum SeratoTags {
    public struct Cue: Equatable, Sendable {
        public var index: Int          // hot cue slot 0…7
        public var positionMs: Int
        public var color: (UInt8, UInt8, UInt8)
        public var name: String
        public init(index: Int, positionMs: Int, color: (UInt8, UInt8, UInt8), name: String) {
            self.index = index; self.positionMs = positionMs; self.color = color; self.name = name
        }
        public static func == (a: Cue, b: Cue) -> Bool {
            a.index == b.index && a.positionMs == b.positionMs && a.color == b.color && a.name == b.name
        }
    }

    // Serato's default hot cue colours (slot order).
    public static let hotCueColors: [(UInt8, UInt8, UInt8)] = [
        (0xCC, 0x00, 0x00), (0xCC, 0x88, 0x00), (0x00, 0x00, 0xCC), (0xCC, 0xCC, 0x00),
        (0x00, 0xCC, 0x00), (0xCC, 0x00, 0xCC), (0x00, 0xCC, 0xCC), (0x88, 0x00, 0xCC),
    ]

    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func readBE32(_ d: Data, _ at: Int) -> Int {
        let i = d.startIndex + at
        return (Int(d[i]) << 24) | (Int(d[i + 1]) << 16) | (Int(d[i + 2]) << 8) | Int(d[i + 3])
    }

    // MARK: Markers2

    /// Builds the decoded Markers2 payload (version + entries + terminator).
    static func markersPayload(cues: [Cue], trackColor: (UInt8, UInt8, UInt8)? = nil, bpmLock: Bool = false) -> Data {
        var d = Data([0x01, 0x01])
        if let c = trackColor {
            d.append(contentsOf: Array("COLOR".utf8)); d.append(0)
            d.append(contentsOf: be32(4))
            d.append(contentsOf: [0x00, c.0, c.1, c.2])
        }
        for cue in cues.sorted(by: { $0.index < $1.index }) {
            var body = Data([0x00, UInt8(max(0, min(7, cue.index)))])
            body.append(contentsOf: be32(max(0, cue.positionMs)))
            body.append(0x00)
            body.append(contentsOf: [cue.color.0, cue.color.1, cue.color.2])
            body.append(contentsOf: [0x00, 0x00])
            body.append(contentsOf: Array(cue.name.utf8))
            body.append(0x00)
            d.append(contentsOf: Array("CUE".utf8)); d.append(0)
            d.append(contentsOf: be32(body.count))
            d.append(body)
        }
        d.append(contentsOf: Array("BPMLOCK".utf8)); d.append(0)
        d.append(contentsOf: be32(1))
        d.append(bpmLock ? 0x01 : 0x00)
        d.append(0x00)
        return d
    }

    /// Base64 with line breaks every 72 characters, as Serato writes it.
    static func seratoBase64(_ d: Data) -> Data {
        let s = d.base64EncodedString()
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 72, limitedBy: s.endIndex) ?? s.endIndex
            out += s[i..<j]
            if j < s.endIndex { out += "\n" }
            i = j
        }
        return Data(out.utf8)
    }

    /// The bytes stored in the ID3 GEOB frame body (after the GEOB header fields).
    public static func markersGEOBData(cues: [Cue], trackColor: (UInt8, UInt8, UInt8)? = nil) -> Data {
        var d = Data([0x01, 0x01])
        d.append(seratoBase64(markersPayload(cues: cues, trackColor: trackColor)))
        return d
    }

    /// Parses Markers2 GEOB data back into cues.
    public static func parseMarkersGEOBData(_ data: Data) -> [Cue] {
        guard data.count > 2 else { return [] }
        let b64 = String(decoding: data.dropFirst(2), as: UTF8.self).filter { !$0.isWhitespace && $0 != "\0" }
        var padded = b64
        while padded.count % 4 != 0 { padded += "=" }
        guard let payload = Data(base64Encoded: padded), payload.count > 2 else { return [] }
        var cues: [Cue] = []
        var pos = 2
        let bytes = [UInt8](payload)
        while pos < bytes.count {
            if bytes[pos] == 0 { break }
            guard let nul = bytes[pos...].firstIndex(of: 0) else { break }
            let name = String(decoding: bytes[pos..<nul], as: UTF8.self)
            pos = nul + 1
            guard pos + 4 <= bytes.count else { break }
            let len = (Int(bytes[pos]) << 24) | (Int(bytes[pos + 1]) << 16) | (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
            pos += 4
            guard pos + len <= bytes.count else { break }
            let body = Array(bytes[pos..<(pos + len)])
            pos += len
            if name == "CUE", body.count >= 13 {
                let index = Int(body[1])
                let ms = (Int(body[2]) << 24) | (Int(body[3]) << 16) | (Int(body[4]) << 8) | Int(body[5])
                let color = (body[7], body[8], body[9])
                let nameBytes = body[12...].prefix { $0 != 0 }
                cues.append(Cue(index: index, positionMs: ms, color: color, name: String(decoding: nameBytes, as: UTF8.self)))
            }
        }
        return cues
    }

    // MARK: BeatGrid

    /// Serato BeatGrid GEOB data for a constant tempo: one terminal marker at the first beat.
    public static func beatGridGEOBData(firstBeatSeconds: Double, bpm: Double) -> Data {
        var d = Data([0x01, 0x00])
        d.append(contentsOf: be32(1))
        d.append(contentsOf: Float(firstBeatSeconds).bitPattern.bigEndian.bytes)
        d.append(contentsOf: Float(bpm).bitPattern.bigEndian.bytes)
        d.append(0x00)   // footer
        return d
    }

    public static func parseBeatGridGEOBData(_ data: Data) -> (firstBeat: Double, bpm: Double)? {
        guard data.count >= 15 else { return nil }
        let count = readBE32(data, 2)
        guard count >= 1 else { return nil }
        // Terminal marker is the last: position (float) + bpm (float).
        let base = 6 + (count - 1) * 8
        guard data.count >= base + 8 else { return nil }
        func f32(_ at: Int) -> Float {
            let i = data.startIndex + at
            let bits = (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
            return Float(bitPattern: bits)
        }
        return (Double(f32(base)), Double(f32(base + 4)))
    }

    // MARK: Container encodings

    static let octetStream = "application/octet-stream"

    /// Text stored in MP4 freeform atoms / FLAC comments: base64 of mime + NUL NUL + name + NUL + geob data.
    public static func containerText(name: String, geobData: Data) -> String {
        var d = Data(octetStream.utf8)
        d.append(contentsOf: [0, 0])
        d.append(contentsOf: Array(name.utf8))
        d.append(0)
        d.append(geobData)
        return d.base64EncodedString()
    }

    public static func geobData(fromContainerText text: String, expectedName: String) -> Data? {
        let cleaned = text.filter { !$0.isWhitespace }
        var padded = cleaned
        while padded.count % 4 != 0 { padded += "=" }
        guard let d = Data(base64Encoded: padded) else { return nil }
        let bytes = [UInt8](d)
        guard let mimeEnd = bytes.firstIndex(of: 0), mimeEnd + 2 < bytes.count else { return nil }
        var pos = mimeEnd + 2   // skip NUL NUL
        guard let nameEnd = bytes[pos...].firstIndex(of: 0) else { return nil }
        let name = String(decoding: bytes[pos..<nameEnd], as: UTF8.self)
        guard name == expectedName else { return nil }
        pos = nameEnd + 1
        return Data(bytes[pos...])
    }

    // MARK: ID3 GEOB frames

    static func geobFrame(description: String, data: Data) -> ID3Frame {
        var body = Data([0x00])                                   // ISO-8859-1
        body.append(contentsOf: Array(octetStream.utf8)); body.append(0)   // MIME
        body.append(0)                                            // filename (empty)
        body.append(contentsOf: Array(description.utf8)); body.append(0)   // description
        body.append(data)
        return ID3Frame(id: "GEOB", data: body)
    }

    static func geobDescription(_ frame: ID3Frame) -> (description: String, data: Data)? {
        guard frame.id == "GEOB", frame.data.count > 4 else { return nil }
        let bytes = [UInt8](frame.data)
        let enc = bytes[0]
        var pos = 1
        guard let mimeEnd = bytes[pos...].firstIndex(of: 0) else { return nil }
        pos = mimeEnd + 1
        // filename and description are terminated per encoding
        func readTerminated() -> String? {
            if enc == 1 || enc == 2 {
                var i = pos
                while i + 1 < bytes.count {
                    if bytes[i] == 0 && bytes[i + 1] == 0 {
                        let s = ID3Tag.decodeText(Data(bytes[pos..<i]), encoding: enc)
                        pos = i + 2
                        return s
                    }
                    i += 2
                }
                return nil
            }
            guard let end = bytes[pos...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: bytes[pos..<end], as: UTF8.self)
            pos = end + 1
            return s
        }
        guard readTerminated() != nil, let desc = readTerminated() else { return nil }
        return (desc, Data(bytes[pos...]))
    }

    /// Replaces the Serato Markers2 / BeatGrid GEOB frames in an ID3 tag.
    public static func apply(cues: [Cue], firstBeat: Double?, bpm: Double?, to tag: inout ID3Tag) {
        tag.frames.removeAll { f in
            guard let g = geobDescription(f) else { return false }
            return g.description == "Serato Markers2" || (firstBeat != nil && g.description == "Serato BeatGrid")
        }
        tag.frames.append(geobFrame(description: "Serato Markers2", data: markersGEOBData(cues: cues)))
        if let fb = firstBeat, let bpm, bpm > 0 {
            tag.frames.append(geobFrame(description: "Serato BeatGrid", data: beatGridGEOBData(firstBeatSeconds: fb, bpm: bpm)))
        }
    }

    public static func cues(in tag: ID3Tag) -> [Cue] {
        for f in tag.frames {
            if let g = geobDescription(f), g.description == "Serato Markers2" { return parseMarkersGEOBData(g.data) }
        }
        return []
    }

    public static func beatGrid(in tag: ID3Tag) -> (firstBeat: Double, bpm: Double)? {
        for f in tag.frames {
            if let g = geobDescription(f), g.description == "Serato BeatGrid" { return parseBeatGridGEOBData(g.data) }
        }
        return nil
    }

    /// Converts analysis cue points to Serato hot cues (slots 0…7).
    public static func cues(from result: AnalysisResult) -> [Cue] {
        result.cuePoints.prefix(8).enumerated().map { i, c in
            Cue(index: i, positionMs: Int((c.time * 1000).rounded()), color: hotCueColors[i % hotCueColors.count], name: c.name)
        }
    }
}

extension UInt32 {
    var bytes: [UInt8] { withUnsafeBytes(of: self) { Array($0) } }
}
