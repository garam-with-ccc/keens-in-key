import Foundation

/// Vorbis comment block (used by FLAC).
public struct VorbisComment: Equatable, Sendable {
    public var vendor: String
    public var fields: [(key: String, value: String)]

    public init(vendor: String = "Keens In Key", fields: [(key: String, value: String)] = []) {
        self.vendor = vendor
        self.fields = fields
    }

    public static func == (a: VorbisComment, b: VorbisComment) -> Bool {
        a.vendor == b.vendor && a.fields.map { "\($0.key)=\($0.value)" } == b.fields.map { "\($0.key)=\($0.value)" }
    }

    public func first(_ key: String) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public func all(_ key: String) -> [String] {
        fields.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map(\.value)
    }

    public mutating func set(_ key: String, _ value: String?) {
        fields.removeAll { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        if let value, !value.isEmpty { fields.append((key.uppercased(), value)) }
    }

    static func le32(_ d: Data, _ at: Int) -> Int {
        Int(d[d.startIndex + at]) | (Int(d[d.startIndex + at + 1]) << 8) | (Int(d[d.startIndex + at + 2]) << 16) | (Int(d[d.startIndex + at + 3]) << 24)
    }

    static func le32Bytes(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

    public static func parse(_ d: Data) throws -> VorbisComment {
        guard d.count >= 8 else { throw ID3Error.malformed("vorbis comment too short") }
        let vlen = le32(d, 0)
        guard 4 + vlen + 4 <= d.count else { throw ID3Error.malformed("vorbis vendor length") }
        let vendor = String(data: d.subdata(in: (d.startIndex + 4)..<(d.startIndex + 4 + vlen)), encoding: .utf8) ?? ""
        var pos = 4 + vlen
        let count = le32(d, pos)
        pos += 4
        var fields: [(String, String)] = []
        for _ in 0..<count {
            guard pos + 4 <= d.count else { break }
            let len = le32(d, pos)
            pos += 4
            guard pos + len <= d.count else { break }
            let s = String(data: d.subdata(in: (d.startIndex + pos)..<(d.startIndex + pos + len)), encoding: .utf8) ?? ""
            pos += len
            if let eq = s.firstIndex(of: "=") {
                fields.append((String(s[s.startIndex..<eq]), String(s[s.index(after: eq)...])))
            }
        }
        return VorbisComment(vendor: vendor, fields: fields)
    }

    public func encode() -> Data {
        var out = Data()
        let v = vendor.data(using: .utf8) ?? Data()
        out.append(contentsOf: VorbisComment.le32Bytes(v.count))
        out.append(v)
        out.append(contentsOf: VorbisComment.le32Bytes(fields.count))
        for f in fields {
            let s = "\(f.key)=\(f.value)".data(using: .utf8) ?? Data()
            out.append(contentsOf: VorbisComment.le32Bytes(s.count))
            out.append(s)
        }
        return out
    }
}

/// Reads and writes the VORBIS_COMMENT metadata block of FLAC files.
public enum FLACFile {
    struct Block {
        var type: UInt8
        var data: Data
    }

    /// Parses the metadata section. Returns (offset of "fLaC", blocks, offset of first audio frame).
    static func parse(_ data: Data) throws -> (start: Int, blocks: [Block], audioStart: Int) {
        var pos = ID3Tag.tagLength(in: data)   // some FLAC files carry an ID3v2 tag first
        guard data.count >= pos + 4, data[pos] == 0x66, data[pos + 1] == 0x4C, data[pos + 2] == 0x61, data[pos + 3] == 0x43 else {
            throw ID3Error.malformed("not a FLAC file")
        }
        let start = pos
        pos += 4
        var blocks: [Block] = []
        var last = false
        while !last {
            guard pos + 4 <= data.count else { throw ID3Error.malformed("truncated metadata") }
            let header = data[pos]
            last = (header & 0x80) != 0
            let type = header & 0x7F
            let len = (Int(data[pos + 1]) << 16) | (Int(data[pos + 2]) << 8) | Int(data[pos + 3])
            guard pos + 4 + len <= data.count else { throw ID3Error.malformed("truncated block") }
            blocks.append(Block(type: type, data: data.subdata(in: (pos + 4)..<(pos + 4 + len))))
            pos += 4 + len
        }
        return (start, blocks, pos)
    }

    public static func readComment(_ url: URL) throws -> VorbisComment? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (_, blocks, _) = try parse(data)
        guard let b = blocks.first(where: { $0.type == 4 }) else { return nil }
        return try VorbisComment.parse(b.data)
    }

    /// Stream info: (sampleRate, channels, totalSamples)
    public static func streamInfo(_ url: URL) -> (sampleRate: Int, channels: Int, totalSamples: Int)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let (_, blocks, _) = try? parse(data),
              let si = blocks.first(where: { $0.type == 0 }), si.data.count >= 18 else { return nil }
        let d = [UInt8](si.data)
        let sampleRate = (Int(d[10]) << 12) | (Int(d[11]) << 4) | (Int(d[12]) >> 4)
        let channels = Int((d[12] >> 1) & 0x07) + 1
        let total = (Int(d[13] & 0x0F) << 32) | (Int(d[14]) << 24) | (Int(d[15]) << 16) | (Int(d[16]) << 8) | Int(d[17])
        return (sampleRate, channels, total)
    }

    /// Replaces the Vorbis comment block, writing in place when the metadata section can absorb the change.
    public static func writeComment(_ comment: VorbisComment, to url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (start, blocks, audioStart) = try parse(data)
        var newBlocks = blocks.filter { $0.type != 1 && $0.type != 4 }   // drop padding and old comment
        let commentBlock = Block(type: 4, data: comment.encode())
        if let idx = newBlocks.firstIndex(where: { $0.type == 0 }) { newBlocks.insert(commentBlock, at: idx + 1) }
        else { newBlocks.insert(commentBlock, at: 0) }

        let oldMetaLen = audioStart - (start + 4)
        let newMetaLen = newBlocks.reduce(0) { $0 + 4 + $1.data.count }
        let inPlace = newMetaLen + 4 <= oldMetaLen
        let paddingLen = inPlace ? (oldMetaLen - newMetaLen - 4) : 4096
        newBlocks.append(Block(type: 1, data: Data(count: paddingLen)))

        var meta = Data()
        for (i, b) in newBlocks.enumerated() {
            let isLast = i == newBlocks.count - 1
            let len = b.data.count
            meta.append(UInt8(b.type) | (isLast ? 0x80 : 0))
            meta.append(contentsOf: [UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
            meta.append(b.data)
        }

        if inPlace {
            precondition(meta.count == oldMetaLen)
            guard let fh = try? FileHandle(forWritingTo: url) else { throw ID3Error.io("cannot open for writing") }
            defer { try? fh.close() }
            fh.seek(toFileOffset: UInt64(start + 4))
            fh.write(meta)
            return
        }
        let head = data.subdata(in: 0..<(start + 4))
        try ID3File.rewrite(url: url, skippingPrefix: audioStart) { out in
            out.write(head)
            out.write(meta)
        }
    }
}
