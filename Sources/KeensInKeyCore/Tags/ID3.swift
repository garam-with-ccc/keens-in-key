import Foundation

/// One ID3v2 frame in v2.3 / v2.4 layout.
public struct ID3Frame: Equatable, Sendable {
    public var id: String
    public var flags: UInt16
    public var data: Data

    public init(id: String, flags: UInt16 = 0, data: Data) {
        self.id = id; self.flags = flags; self.data = data
    }
}

public enum ID3Error: Error, LocalizedError {
    case malformed(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let m): return "Malformed ID3 tag: \(m)"
        case .io(let m): return "Tag I/O error: \(m)"
        }
    }
}

/// An ID3v2.3 / v2.4 tag. Unknown frames are preserved verbatim.
public struct ID3Tag: Equatable, Sendable {
    public var version: UInt8      // minor version: 3 or 4
    public var frames: [ID3Frame]

    public init(version: UInt8 = 3, frames: [ID3Frame] = []) {
        self.version = version
        self.frames = frames
    }

    // MARK: - Sync-safe helpers

    static func syncsafe(_ b: [UInt8]) -> Int {
        return (Int(b[0] & 0x7F) << 21) | (Int(b[1] & 0x7F) << 14) | (Int(b[2] & 0x7F) << 7) | Int(b[3] & 0x7F)
    }

    static func syncsafeBytes(_ v: Int) -> [UInt8] {
        return [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    static func be32(_ b: [UInt8]) -> Int {
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }

    static func be32Bytes(_ v: Int) -> [UInt8] {
        return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func deunsync(_ d: Data) -> Data {
        var out = Data(capacity: d.count)
        var i = d.startIndex
        while i < d.endIndex {
            let b = d[i]
            out.append(b)
            if b == 0xFF, i + 1 < d.endIndex, d[i + 1] == 0x00 { i += 2 } else { i += 1 }
        }
        return out
    }

    /// Total size in bytes of the ID3v2 tag at the start of `data` (0 if none).
    public static func tagLength(in data: Data) -> Int {
        guard data.count >= 10 else { return 0 }
        let b = [UInt8](data.prefix(10))
        guard b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, b[3] < 0xFF, b[4] < 0xFF else { return 0 }
        guard b[6] < 0x80, b[7] < 0x80, b[8] < 0x80, b[9] < 0x80 else { return 0 }
        let size = syncsafe(Array(b[6..<10]))
        let footer = (b[3] == 4 && (b[5] & 0x10) != 0) ? 10 : 0
        return 10 + size + footer
    }

    // MARK: - Parsing

    /// Parses the tag at the start of `data`. Returns nil when no tag is present.
    public static func parse(_ data: Data) throws -> ID3Tag? {
        let total = tagLength(in: data)
        guard total > 0 else { return nil }
        let hdr = [UInt8](data.prefix(10))
        let major = hdr[3]
        guard (2...4).contains(major) else { throw ID3Error.malformed("unsupported version 2.\(major)") }
        let flags = hdr[5]
        let size = syncsafe(Array(hdr[6..<10]))
        var body = data.subdata(in: 10..<min(data.count, 10 + size))
        let tagUnsync = (flags & 0x80) != 0
        if tagUnsync { body = deunsync(body) }

        var pos = 0
        if (flags & 0x40) != 0, major >= 3 {   // extended header
            guard body.count >= 4 else { throw ID3Error.malformed("extended header") }
            let eb = [UInt8](body.prefix(4))
            if major == 3 { pos = 4 + be32(eb) } else { pos = syncsafe(eb) }
        }

        var tag = ID3Tag(version: major == 2 ? 3 : major, frames: [])
        let bytes = [UInt8](body)
        let headerLen = major == 2 ? 6 : 10
        while pos + headerLen <= bytes.count {
            if bytes[pos] == 0 { break }   // padding
            let idLen = major == 2 ? 3 : 4
            let idBytes = Array(bytes[pos..<(pos + idLen)])
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else { break }
            var id = String(decoding: idBytes, as: UTF8.self)
            let frameSize: Int
            var frameFlags: UInt16 = 0
            switch major {
            case 2:
                frameSize = (Int(bytes[pos + 3]) << 16) | (Int(bytes[pos + 4]) << 8) | Int(bytes[pos + 5])
            case 3:
                frameSize = be32(Array(bytes[(pos + 4)..<(pos + 8)]))
                frameFlags = (UInt16(bytes[pos + 8]) << 8) | UInt16(bytes[pos + 9])
            default:
                frameSize = syncsafe(Array(bytes[(pos + 4)..<(pos + 8)]))
                frameFlags = (UInt16(bytes[pos + 8]) << 8) | UInt16(bytes[pos + 9])
            }
            let start = pos + headerLen
            guard frameSize >= 0, start + frameSize <= bytes.count else { break }
            var fdata = Data(bytes[start..<(start + frameSize)])
            pos = start + frameSize
            if frameSize == 0 { continue }

            if major == 4 {
                if (frameFlags & 0x0001) != 0, fdata.count >= 4 {   // data length indicator
                    fdata = fdata.subdata(in: 4..<fdata.count)
                    frameFlags &= ~0x0001
                }
                if (frameFlags & 0x0002) != 0 {                     // frame-level unsynchronisation
                    if !tagUnsync { fdata = deunsync(fdata) }
                    frameFlags &= ~0x0002
                }
                if (frameFlags & 0x0008) != 0 || (frameFlags & 0x0004) != 0 { continue }  // compressed / encrypted: drop
            } else if major == 3 {
                if (frameFlags & 0x0080) != 0 || (frameFlags & 0x0040) != 0 { continue }  // compressed / encrypted: drop
                frameFlags &= ~0x0020   // grouping identity bit is preserved with the data; leave as-is
            }
            if major == 2 {
                guard let converted = convertV22Frame(id: id, data: fdata) else { continue }
                id = converted.id
                fdata = converted.data
            }
            tag.frames.append(ID3Frame(id: id, flags: frameFlags, data: fdata))
        }
        return tag
    }

    static let v22Map: [String: String] = [
        "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4",
        "TAL": "TALB", "TYE": "TYER", "TCO": "TCON", "TRK": "TRCK", "TPA": "TPOS", "TKE": "TKEY", "TBP": "TBPM",
        "COM": "COMM", "TCM": "TCOM", "TXX": "TXXX", "ULT": "USLT", "TEN": "TENC", "TSS": "TSSE", "TLE": "TLEN",
        "TXT": "TEXT", "WXX": "WXXX", "TCP": "TCMP", "TDA": "TDAT", "TIM": "TIME", "TOR": "TORY", "TPB": "TPUB",
        "TSC": "TSOC", "TST": "TSOT", "TSA": "TSOA", "TSP": "TSOP", "TS2": "TSO2", "TLA": "TLAN", "TMT": "TMED",
    ]

    static func convertV22Frame(id: String, data: Data) -> (id: String, data: Data)? {
        if id == "PIC" {
            // enc(1) format(3) type(1) desc… data  →  enc(1) mime\0 type(1) desc… data
            guard data.count >= 5 else { return nil }
            let enc = data[data.startIndex]
            let fmt = String(decoding: data[(data.startIndex + 1)..<(data.startIndex + 4)], as: UTF8.self).uppercased()
            let mime = fmt == "PNG" ? "image/png" : (fmt == "JPG" ? "image/jpeg" : "image/\(fmt.lowercased())")
            var out = Data([enc])
            out.append(mime.data(using: .isoLatin1)!)
            out.append(0)
            out.append(data.subdata(in: (data.startIndex + 4)..<data.endIndex))
            return ("APIC", out)
        }
        guard let newId = v22Map[id] else { return nil }
        return (newId, data)
    }

    // MARK: - Text helpers

    static func decodeText(_ d: Data, encoding: UInt8) -> String {
        guard !d.isEmpty else { return "" }
        var s: String?
        switch encoding {
        case 0: s = String(data: d, encoding: .isoLatin1)
        case 1:
            if d.count >= 2 {
                let b0 = d[d.startIndex], b1 = d[d.startIndex + 1]
                if b0 == 0xFF && b1 == 0xFE { s = String(data: d.dropFirst(2), encoding: .utf16LittleEndian) }
                else if b0 == 0xFE && b1 == 0xFF { s = String(data: d.dropFirst(2), encoding: .utf16BigEndian) }
                else { s = String(data: d, encoding: .utf16BigEndian) }
            }
        case 2: s = String(data: d, encoding: .utf16BigEndian)
        default: s = String(data: d, encoding: .utf8)
        }
        if s == nil { s = String(data: d, encoding: .isoLatin1) }
        return (s ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Splits off a terminated string (per encoding) and returns (string, remainder).
    static func splitTerminated(_ d: Data, encoding: UInt8) -> (String, Data) {
        let wide = encoding == 1 || encoding == 2
        var i = d.startIndex
        if wide {
            while i + 1 < d.endIndex {
                if d[i] == 0 && d[i + 1] == 0 { return (decodeText(d[d.startIndex..<i], encoding: encoding), d[(i + 2)...]) }
                i += 2
            }
        } else {
            while i < d.endIndex {
                if d[i] == 0 { return (decodeText(d[d.startIndex..<i], encoding: encoding), d[(i + 1)...]) }
                i += 1
            }
        }
        return (decodeText(d, encoding: encoding), Data())
    }

    /// Chooses an encoding byte and encodes `s` for this tag version.
    func encodeText(_ s: String) -> (UInt8, Data) {
        if let latin = s.data(using: .isoLatin1) { return (0, latin) }
        if version == 4 { return (3, s.data(using: .utf8) ?? Data()) }
        var d = Data([0xFF, 0xFE])
        d.append(s.data(using: .utf16LittleEndian) ?? Data())
        return (1, d)
    }

    func terminator(for encoding: UInt8) -> Data { (encoding == 1 || encoding == 2) ? Data([0, 0]) : Data([0]) }

    // MARK: - Accessors

    public func frames(withId id: String) -> [ID3Frame] { frames.filter { $0.id == id } }

    /// First text frame value, e.g. text("TIT2").
    public func text(_ id: String) -> String? {
        guard let f = frames.first(where: { $0.id == id }), f.data.count >= 1 else { return nil }
        let enc = f.data[f.data.startIndex]
        let body = f.data.dropFirst()
        let s = ID3Tag.decodeText(body, encoding: enc)
        let parts = s.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return parts.isEmpty ? (s.isEmpty ? nil : s) : parts.joined(separator: " / ")
    }

    public mutating func setText(_ id: String, _ value: String?) {
        frames.removeAll { $0.id == id }
        guard let value, !value.isEmpty else { return }
        let (enc, d) = encodeText(value)
        var body = Data([enc])
        body.append(d)
        frames.append(ID3Frame(id: id, data: body))
    }

    /// COMM frames decoded as (language, description, text).
    public func comments() -> [(language: String, description: String, text: String)] {
        frames.filter { $0.id == "COMM" }.compactMap { f in
            guard f.data.count >= 4 else { return nil }
            let enc = f.data[f.data.startIndex]
            let lang = String(decoding: f.data[(f.data.startIndex + 1)..<(f.data.startIndex + 4)], as: UTF8.self)
            let rest = f.data[(f.data.startIndex + 4)...]
            let (desc, textData) = ID3Tag.splitTerminated(rest, encoding: enc)
            return (lang, desc, ID3Tag.decodeText(textData, encoding: enc))
        }
    }

    /// The main comment (empty description, or the first one).
    public func comment() -> String? {
        let all = comments().filter { !$0.description.lowercased().hasPrefix("itunnorm") && !$0.description.lowercased().hasPrefix("itunsmpb") && !$0.description.lowercased().hasPrefix("itunpgap") }
        return (all.first { $0.description.isEmpty } ?? all.first)?.text
    }

    public mutating func setComment(_ text: String?, description: String = "", language: String = "eng") {
        // Remove existing comments with the same description (any language).
        frames.removeAll { f in
            guard f.id == "COMM", f.data.count >= 4 else { return false }
            let enc = f.data[f.data.startIndex]
            let (desc, _) = ID3Tag.splitTerminated(f.data[(f.data.startIndex + 4)...], encoding: enc)
            return desc == description
        }
        guard let text, !text.isEmpty else { return }
        let (enc, textData) = encodeText(description + "\u{1}" + text)   // encode both with one encoding
        _ = textData
        let (enc2, descData) = encodeText(description)
        let useEnc = max(enc, enc2)
        var body = Data([useEnc])
        body.append(language.data(using: .isoLatin1)?.prefix(3) ?? Data("eng".utf8))
        body.append(reencode(description, enc: useEnc, from: descData, originalEnc: enc2))
        body.append(terminator(for: useEnc))
        body.append(reencode(text, enc: useEnc, from: Data(), originalEnc: 255))
        frames.append(ID3Frame(id: "COMM", data: body))
    }

    private func reencode(_ s: String, enc: UInt8, from: Data, originalEnc: UInt8) -> Data {
        if originalEnc == enc { return from }
        switch enc {
        case 0: return s.data(using: .isoLatin1) ?? Data()
        case 3: return s.data(using: .utf8) ?? Data()
        default:
            var d = Data([0xFF, 0xFE]); d.append(s.data(using: .utf16LittleEndian) ?? Data()); return d
        }
    }

    /// TXXX user text by description.
    public func userText(_ description: String) -> String? {
        for f in frames where f.id == "TXXX" && f.data.count >= 2 {
            let enc = f.data[f.data.startIndex]
            let (desc, val) = ID3Tag.splitTerminated(f.data[(f.data.startIndex + 1)...], encoding: enc)
            if desc.caseInsensitiveCompare(description) == .orderedSame { return ID3Tag.decodeText(val, encoding: enc) }
        }
        return nil
    }

    public mutating func setUserText(_ description: String, _ value: String?) {
        frames.removeAll { f in
            guard f.id == "TXXX", f.data.count >= 2 else { return false }
            let enc = f.data[f.data.startIndex]
            let (desc, _) = ID3Tag.splitTerminated(f.data[(f.data.startIndex + 1)...], encoding: enc)
            return desc.caseInsensitiveCompare(description) == .orderedSame
        }
        guard let value, !value.isEmpty else { return }
        let (enc, _) = encodeText(description + value)
        var body = Data([enc])
        body.append(reencode(description, enc: enc, from: Data(), originalEnc: 255))
        body.append(terminator(for: enc))
        body.append(reencode(value, enc: enc, from: Data(), originalEnc: 255))
        frames.append(ID3Frame(id: "TXXX", data: body))
    }

    // Convenience accessors
    public var title: String? { get { text("TIT2") } set { setText("TIT2", newValue) } }
    public var artist: String? { get { text("TPE1") } set { setText("TPE1", newValue) } }
    public var album: String? { get { text("TALB") } set { setText("TALB", newValue) } }
    public var initialKey: String? { get { text("TKEY") } set { setText("TKEY", newValue) } }
    public var bpm: String? { get { text("TBPM") } set { setText("TBPM", newValue) } }
    public var genre: String? { get { text("TCON") } set { setText("TCON", newValue) } }
    /// Grouping: iTunes uses GRP1, others TIT1 (content group).
    public var grouping: String? {
        get { text("GRP1") ?? text("TIT1") }
        set { setText("TIT1", newValue); setText("GRP1", newValue) }
    }

    // MARK: - Encoding

    /// Serialises the tag with `padding` zero bytes appended.
    public func encode(padding: Int = 1024) -> Data {
        var body = Data()
        for f in frames {
            guard f.id.count == 4, let idData = f.id.data(using: .ascii) else { continue }
            body.append(idData)
            let size = f.data.count
            body.append(contentsOf: version == 4 ? ID3Tag.syncsafeBytes(size) : ID3Tag.be32Bytes(size))
            body.append(contentsOf: [UInt8(f.flags >> 8), UInt8(f.flags & 0xFF)])
            body.append(f.data)
        }
        body.append(Data(count: max(0, padding)))
        var out = Data("ID3".utf8)
        out.append(contentsOf: [version, 0, 0])
        out.append(contentsOf: ID3Tag.syncsafeBytes(body.count))
        out.append(body)
        return out
    }

    /// Size of the encoded tag without padding.
    public var encodedSizeWithoutPadding: Int { encode(padding: 0).count }
}

// MARK: - MP3 / AIFF / WAV file I/O

public enum ID3File {
    /// Reads the ID3v2 tag from an MP3 (tag at the start of the file).
    public static func readMP3(_ url: URL) throws -> (tag: ID3Tag?, length: Int) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ID3Error.io("cannot open \(url.lastPathComponent)") }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 10)
        let len = ID3Tag.tagLength(in: head)
        guard len > 0 else { return (nil, 0) }
        fh.seek(toFileOffset: 0)
        let data = fh.readData(ofLength: len)
        return (try ID3Tag.parse(data), len)
    }

    /// Writes (replaces or prepends) the ID3v2 tag on an MP3, in place when the new tag fits.
    public static func writeMP3(_ tag: ID3Tag, to url: URL) throws {
        let (_, oldLen) = try readMP3(url)
        let needed = tag.encodedSizeWithoutPadding
        if oldLen >= needed {
            let data = tag.encode(padding: oldLen - needed)
            precondition(data.count == oldLen)
            guard let fh = try? FileHandle(forWritingTo: url) else { throw ID3Error.io("cannot open for writing") }
            defer { try? fh.close() }
            fh.seek(toFileOffset: 0)
            fh.write(data)
            return
        }
        let data = tag.encode(padding: 2048)
        try rewrite(url: url, skippingPrefix: oldLen) { out in
            out.write(data)
        }
    }

    /// Copies `url` to a temp file, letting `prefix` write the new head, then replaces the original.
    static func rewrite(url: URL, skippingPrefix: Int, prefix: (FileHandle) throws -> Void) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).kik-\(UUID().uuidString.prefix(8)).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp), let input = try? FileHandle(forReadingFrom: url) else {
            throw ID3Error.io("cannot create temp file")
        }
        do {
            try prefix(out)
            input.seek(toFileOffset: UInt64(skippingPrefix))
            while true {
                let chunk = input.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                out.write(chunk)
            }
            try out.close()
            try input.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? out.close(); try? input.close()
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.io(error.localizedDescription)
        }
    }

    // MARK: RIFF / FORM containers (WAV, AIFF)

    struct Chunk {
        var id: String
        var offset: Int      // offset of the chunk data
        var size: Int
    }

    /// Enumerates chunks of a RIFF (WAV, little endian) or FORM (AIFF, big endian) file.
    static func chunks(in data: Data) throws -> (bigEndian: Bool, formType: String, chunks: [Chunk]) {
        guard data.count >= 12 else { throw ID3Error.malformed("file too small") }
        let magic = String(decoding: data[0..<4], as: UTF8.self)
        let bigEndian: Bool
        switch magic {
        case "RIFF", "RF64": bigEndian = false
        case "FORM": bigEndian = true
        default: throw ID3Error.malformed("not a RIFF/AIFF file")
        }
        let formType = String(decoding: data[8..<12], as: UTF8.self)
        var out: [Chunk] = []
        var pos = 12
        while pos + 8 <= data.count {
            let id = String(decoding: data[pos..<(pos + 4)], as: UTF8.self)
            let b = [UInt8](data[(pos + 4)..<(pos + 8)])
            let size = bigEndian ? ID3Tag.be32(b) : (Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24))
            let dataStart = pos + 8
            let clamped = min(size, max(0, data.count - dataStart))
            out.append(Chunk(id: id, offset: dataStart, size: clamped))
            pos = dataStart + clamped + (clamped & 1)
            if clamped < size { break }
        }
        return (bigEndian, formType, out)
    }

    static func isID3Chunk(_ id: String) -> Bool { id.uppercased() == "ID3 " }

    /// Reads the ID3 chunk of a WAV or AIFF file.
    public static func readChunked(_ url: URL) throws -> ID3Tag? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (_, _, list) = try chunks(in: data)
        guard let c = list.first(where: { isID3Chunk($0.id) }) else { return nil }
        return try ID3Tag.parse(data.subdata(in: c.offset..<(c.offset + c.size)))
    }

    /// Rewrites a WAV or AIFF file with the given ID3 tag stored in an "ID3 " / "id3 " chunk.
    public static func writeChunked(_ tag: ID3Tag, to url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (bigEndian, formType, list) = try chunks(in: data)
        let tagData = tag.encode(padding: 1024)
        let chunkId = bigEndian ? "ID3 " : "id3 "

        var body = Data()
        func appendChunk(id: String, payload: Data) {
            body.append(id.data(using: .ascii)!)
            let n = payload.count
            if bigEndian { body.append(contentsOf: ID3Tag.be32Bytes(n)) }
            else { body.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]) }
            body.append(payload)
            if n & 1 == 1 { body.append(0) }
        }
        var written = false
        for c in list {
            if isID3Chunk(c.id) {
                if !written { appendChunk(id: chunkId, payload: tagData); written = true }
                continue
            }
            appendChunk(id: c.id, payload: data.subdata(in: c.offset..<(c.offset + c.size)))
        }
        if !written { appendChunk(id: chunkId, payload: tagData) }

        var out = Data()
        out.append(data.subdata(in: 0..<4))
        let total = body.count + 4
        if bigEndian { out.append(contentsOf: ID3Tag.be32Bytes(total)) }
        else { out.append(contentsOf: [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF), UInt8((total >> 16) & 0xFF), UInt8((total >> 24) & 0xFF)]) }
        out.append(formType.data(using: .ascii)!)
        out.append(body)

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).kik-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try out.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.io(error.localizedDescription)
        }
    }
}
