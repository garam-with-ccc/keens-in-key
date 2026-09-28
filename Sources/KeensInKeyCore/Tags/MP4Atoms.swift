import Foundation

/// Minimal MP4 atom editor for iTunes-style freeform metadata (`----` atoms with `mean` / `name` / `data`).
/// Used for atoms AVFoundation cannot write correctly (any mean other than com.apple.iTunes, e.g. Serato's).
public enum MP4Atoms {
    public struct Freeform: Equatable, Sendable {
        public var mean: String
        public var name: String
        /// Raw payload of the `data` child (type indicator + locale + value bytes).
        public var dataAtom: Data
        public init(mean: String, name: String, dataAtom: Data) { self.mean = mean; self.name = name; self.dataAtom = dataAtom }

        public init(mean: String, name: String, text: String) {
            self.mean = mean; self.name = name
            var d = Data([0, 0, 0, 1, 0, 0, 0, 0])   // type 1 = UTF-8, locale 0
            d.append(Data(text.utf8))
            self.dataAtom = d
        }

        public var text: String? {
            guard dataAtom.count >= 8 else { return nil }
            return String(data: dataAtom.dropFirst(8), encoding: .utf8)
        }
    }

    final class Node {
        var type: String
        var children: [Node]?
        var payload: Data          // for leaves: full body; for `meta`: the 4-byte version/flags prefix
        var headerExtra: Data      // bytes between header and children (meta version/flags)
        init(type: String, payload: Data = Data(), children: [Node]? = nil, headerExtra: Data = Data()) {
            self.type = type; self.payload = payload; self.children = children; self.headerExtra = headerExtra
        }

        var size: Int {
            if let children { return 8 + headerExtra.count + children.reduce(0) { $0 + $1.size } }
            return 8 + payload.count
        }

        func serialize(into out: inout Data) {
            let sz = size
            out.append(contentsOf: [UInt8((sz >> 24) & 0xFF), UInt8((sz >> 16) & 0xFF), UInt8((sz >> 8) & 0xFF), UInt8(sz & 0xFF)])
            out.append(MP4Atoms.atomTypeData(type))
            if let children {
                out.append(headerExtra)
                for c in children { c.serialize(into: &out) }
            } else {
                out.append(payload)
            }
        }

        func child(_ t: String) -> Node? { children?.first { $0.type == t } }
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "ilst", "----"]

    static func be32(_ d: Data, _ at: Int) -> Int {
        let i = d.startIndex + at
        return (Int(d[i]) << 24) | (Int(d[i + 1]) << 16) | (Int(d[i + 2]) << 8) | Int(d[i + 3])
    }

    /// Atom types are four raw bytes (e.g. "©cmt" starts with 0xA9); Latin-1 keeps them byte-exact.
    static func atomType(_ d: Data, _ at: Int) -> String {
        String(data: d.subdata(in: (d.startIndex + at)..<(d.startIndex + at + 4)), encoding: .isoLatin1) ?? "????"
    }

    static func atomTypeData(_ t: String) -> Data {
        var d = t.data(using: .isoLatin1) ?? Data("????".utf8)
        if d.count != 4 { d = Data(d.prefix(4)); while d.count < 4 { d.append(0x20) } }
        return d
    }

    /// Parses the atom at `pos` (within `data[pos..<end]`) into a tree; returns the node and its total size.
    static func parse(_ data: Data, at pos: Int, end: Int) throws -> (Node, Int) {
        guard pos + 8 <= end else { throw ID3Error.malformed("truncated atom") }
        var size = be32(data, pos)
        let type = atomType(data, pos + 4)
        var header = 8
        if size == 1 {
            guard pos + 16 <= end else { throw ID3Error.malformed("truncated largesize") }
            let hi = be32(data, pos + 8), lo = be32(data, pos + 12)
            size = (hi << 32) | lo
            header = 16
        } else if size == 0 {
            size = end - pos
        }
        guard size >= header, pos + size <= end else { throw ID3Error.malformed("atom \(type) size") }
        let bodyStart = pos + header, bodyEnd = pos + size
        if containers.contains(type) || type == "meta" {
            var extra = Data()
            var childStart = bodyStart
            if type == "meta" {
                guard bodyStart + 4 <= bodyEnd else { throw ID3Error.malformed("meta") }
                extra = data.subdata(in: (data.startIndex + bodyStart)..<(data.startIndex + bodyStart + 4))
                childStart = bodyStart + 4
            }
            var kids: [Node] = []
            var p = childStart
            while p + 8 <= bodyEnd {
                let (child, csize) = try parse(data, at: p, end: bodyEnd)
                kids.append(child)
                p += csize
            }
            return (Node(type: type, children: kids, headerExtra: extra), size)
        }
        return (Node(type: type, payload: data.subdata(in: (data.startIndex + bodyStart)..<(data.startIndex + bodyEnd))), size)
    }

    struct File {
        var atoms: [Node]          // top level; `mdat` and unknown atoms are leaves (payload kept)
        var offsets: [Int]         // original file offsets of top-level atoms
        var sizes: [Int]
    }

    static func parseFile(_ data: Data) throws -> File {
        var atoms: [Node] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        var pos = 0
        while pos + 8 <= data.count {
            let type = atomType(data, pos + 4)
            if type == "moov" {
                let (node, size) = try parse(data, at: pos, end: data.count)
                atoms.append(node); offsets.append(pos); sizes.append(size)
                pos += size
            } else {
                var size = be32(data, pos)
                var header = 8
                if size == 1 { size = (be32(data, pos + 8) << 32) | be32(data, pos + 12); header = 16 }
                else if size == 0 { size = data.count - pos }
                guard size >= header, pos + size <= data.count else { throw ID3Error.malformed("atom \(type)") }
                // Keep unknown / mdat atoms as opaque leaves (payload includes largesize handling on write).
                let node = Node(type: type, payload: data.subdata(in: (data.startIndex + pos + header)..<(data.startIndex + pos + size)))
                node.headerExtra = header == 16 ? Data([1]) : Data()   // marker: was a largesize atom
                atoms.append(node); offsets.append(pos); sizes.append(size)
                pos += size
            }
        }
        return File(atoms: atoms, offsets: offsets, sizes: sizes)
    }

    static func freeform(from node: Node) -> Freeform? {
        guard node.type == "----", let mean = node.child("mean"), let name = node.child("name"), let data = node.child("data"),
              mean.payload.count >= 4, name.payload.count >= 4 else { return nil }
        return Freeform(mean: String(decoding: mean.payload.dropFirst(4), as: UTF8.self),
                        name: String(decoding: name.payload.dropFirst(4), as: UTF8.self), dataAtom: data.payload)
    }

    static func node(for f: Freeform) -> Node {
        var meanP = Data([0, 0, 0, 0]); meanP.append(Data(f.mean.utf8))
        var nameP = Data([0, 0, 0, 0]); nameP.append(Data(f.name.utf8))
        return Node(type: "----", children: [Node(type: "mean", payload: meanP), Node(type: "name", payload: nameP), Node(type: "data", payload: f.dataAtom)])
    }

    // MARK: Public API

    /// All well-formed freeform atoms in the file.
    public static func readFreeform(_ url: URL) throws -> [Freeform] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let file = try parseFile(data)
        guard let moov = file.atoms.first(where: { $0.type == "moov" }),
              let ilst = moov.child("udta")?.child("meta")?.child("ilst") else { return [] }
        return (ilst.children ?? []).compactMap(freeform(from:))
    }

    public static func readFreeform(_ url: URL, mean: String, name: String) throws -> Freeform? {
        try readFreeform(url).first { $0.mean == mean && $0.name == name }
    }

    /// Adds / replaces freeform atoms (matched by mean + name) and removes malformed `----` atoms.
    /// `remove` lists (mean, name) pairs to delete. Chunk offsets are fixed when `moov` precedes `mdat`.
    public static func writeFreeform(_ url: URL, set atoms: [Freeform], remove: [(String, String)] = []) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var file = try parseFile(data)
        guard let moovIndex = file.atoms.firstIndex(where: { $0.type == "moov" }) else { throw ID3Error.malformed("no moov atom") }
        let moov = file.atoms[moovIndex]
        let oldMoovSize = file.sizes[moovIndex]

        // Ensure udta/meta/ilst exist.
        var udta = moov.child("udta")
        if udta == nil { udta = Node(type: "udta", children: []); moov.children?.append(udta!) }
        var meta = udta!.child("meta")
        if meta == nil {
            var hdlr = Data([0, 0, 0, 0, 0, 0, 0, 0])
            hdlr.append(Data("mdir".utf8)); hdlr.append(Data("appl".utf8)); hdlr.append(Data(count: 9))
            meta = Node(type: "meta", children: [Node(type: "hdlr", payload: hdlr)], headerExtra: Data([0, 0, 0, 0]))
            udta!.children?.append(meta!)
        }
        var ilst = meta!.child("ilst")
        if ilst == nil { ilst = Node(type: "ilst", children: []); meta!.children?.append(ilst!) }

        let replaced = Set(atoms.map { "\($0.mean)\u{0}\($0.name)" } + remove.map { "\($0.0)\u{0}\($0.1)" })
        ilst!.children = (ilst!.children ?? []).filter { node in
            guard node.type == "----" else { return true }
            guard let f = freeform(from: node) else { return false }      // drop malformed freeform atoms
            return !replaced.contains("\(f.mean)\u{0}\(f.name)")
        }
        for f in atoms { ilst!.children?.append(node(for: f)) }

        // Chunk offsets: if moov is before any mdat, data after moov shifts by the size change.
        let delta = moov.size - oldMoovSize
        let moovOffset = file.offsets[moovIndex]
        if delta != 0 {
            let mdatAfterMoov = zip(file.atoms, file.offsets).contains { $0.0.type == "mdat" && $0.1 > moovOffset }
            if mdatAfterMoov {
                try adjustChunkOffsets(in: moov, threshold: moovOffset, delta: delta)
            }
        }

        var out = Data(capacity: data.count + delta)
        for node in file.atoms {
            if node.type == "moov" {
                node.serialize(into: &out)
            } else if node.headerExtra == Data([1]) {   // largesize atom: re-emit with 64-bit size
                let sz = 16 + node.payload.count
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(atomTypeData(node.type))
                out.append(contentsOf: (0..<8).reversed().map { UInt8((sz >> ($0 * 8)) & 0xFF) })
                out.append(node.payload)
            } else {
                node.serialize(into: &out)
            }
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).kik-\(UUID().uuidString.prefix(8)).tmp")
        do {
            try out.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ID3Error.io(error.localizedDescription)
        }
    }

    /// Shifts stco / co64 entries that point past `threshold` by `delta`.
    static func adjustChunkOffsets(in node: Node, threshold: Int, delta: Int) throws {
        guard let children = node.children else { return }
        for c in children {
            if c.type == "stco" {
                var p = c.payload
                guard p.count >= 8 else { continue }
                let count = be32(p, 4)
                for i in 0..<count {
                    let at = 8 + i * 4
                    guard at + 4 <= p.count else { break }
                    let v = be32(p, at)
                    if v > threshold {
                        let nv = v + delta
                        guard nv >= 0, nv <= Int(UInt32.max) else { throw ID3Error.malformed("chunk offset overflow; file too large for stco") }
                        p[p.startIndex + at] = UInt8((nv >> 24) & 0xFF); p[p.startIndex + at + 1] = UInt8((nv >> 16) & 0xFF)
                        p[p.startIndex + at + 2] = UInt8((nv >> 8) & 0xFF); p[p.startIndex + at + 3] = UInt8(nv & 0xFF)
                    }
                }
                c.payload = p
            } else if c.type == "co64" {
                var p = c.payload
                guard p.count >= 8 else { continue }
                let count = be32(p, 4)
                for i in 0..<count {
                    let at = 8 + i * 8
                    guard at + 8 <= p.count else { break }
                    let v = (be32(p, at) << 32) | be32(p, at + 4)
                    if v > threshold {
                        let nv = v + delta
                        for b in 0..<8 { p[p.startIndex + at + b] = UInt8((nv >> ((7 - b) * 8)) & 0xFF) }
                    }
                }
                c.payload = p
            } else if c.children != nil {
                try adjustChunkOffsets(in: c, threshold: threshold, delta: delta)
            }
        }
    }
}
