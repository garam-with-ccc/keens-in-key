import XCTest
@testable import KeensInKeyCore

final class MP4AtomsTests: XCTestCase {
    func atom(_ type: String, _ body: Data) -> Data {
        var d = Data()
        let size = 8 + body.count
        d.append(contentsOf: [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        d.append(type.data(using: .isoLatin1)!)
        d.append(body)
        return d
    }
    func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }

    /// Builds ftyp + moov (with an stco pointing into mdat, a ©cmt atom and an existing freeform atom) + mdat.
    func makeMoovFirstFile() -> (Data, [Int]) {
        let ftyp = atom("ftyp", Data("M4A ".utf8) + Data([0, 0, 0, 0]) + Data("M4A isom".utf8))
        let mdatPayload = Data((0..<600).map { UInt8($0 % 253) })
        // Two chunks inside mdat at payload offsets 0 and 300.
        func build(offsets: [Int]) -> Data {
            var stco = Data([0, 0, 0, 0]) + be32(offsets.count)
            for o in offsets { stco.append(be32(o)) }
            let stbl = atom("stbl", atom("stsd", Data(count: 16)) + atom("stco", stco))
            let minf = atom("minf", atom("smhd", Data(count: 8)) + stbl)
            let mdia = atom("mdia", atom("mdhd", Data(count: 24)) + minf)
            let trak = atom("trak", atom("tkhd", Data(count: 84)) + mdia)
            let cmt = atom("©cmt", atom("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data("hello".utf8)))
            let ff = atom("----", atom("mean", Data([0, 0, 0, 0]) + Data("com.example".utf8)) + atom("name", Data([0, 0, 0, 0]) + Data("thing".utf8)) + atom("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data("keep".utf8)))
            let ilst = atom("ilst", cmt + ff)
            let meta = atom("meta", Data([0, 0, 0, 0]) + atom("hdlr", Data(count: 25)) + ilst)
            let udta = atom("udta", meta)
            return atom("moov", atom("mvhd", Data(count: 100)) + trak + udta)
        }
        let moov0 = build(offsets: [0, 0])
        let mdatStart = ftyp.count + moov0.count + 8
        let moov = build(offsets: [mdatStart, mdatStart + 300])
        XCTAssertEqual(moov.count, moov0.count)
        return (ftyp + moov + atom("mdat", mdatPayload), [mdatStart, mdatStart + 300])
    }

    func testWriteFreeformFixesChunkOffsetsWhenMoovPrecedesMdat() throws {
        let (data, offsets) = makeMoovFirstFile()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moovfirst-\(UUID().uuidString).m4a")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk0 = data.subdata(in: offsets[0]..<(offsets[0] + 300))
        let chunk1 = data.subdata(in: offsets[1]..<(offsets[1] + 300))

        XCTAssertEqual(try MP4Atoms.readFreeform(url), [MP4Atoms.Freeform(mean: "com.example", name: "thing", text: "keep")])
        let serato = MP4Atoms.Freeform(mean: "com.serato.dj", name: "markersv2", text: String(repeating: "A", count: 150))
        try MP4Atoms.writeFreeform(url, set: [serato])

        let out = try Data(contentsOf: url)
        let delta = out.count - data.count
        XCTAssertGreaterThan(delta, 150)
        // stco entries moved by delta and still point at the same bytes.
        let file = try MP4Atoms.parseFile(out)
        let moov = file.atoms.first { $0.type == "moov" }!
        let stco = moov.child("trak")!.child("mdia")!.child("minf")!.child("stbl")!.child("stco")!
        let o0 = MP4Atoms.be32(stco.payload, 8), o1 = MP4Atoms.be32(stco.payload, 12)
        XCTAssertEqual(o0, offsets[0] + delta)
        XCTAssertEqual(o1, offsets[1] + delta)
        XCTAssertEqual(out.subdata(in: o0..<(o0 + 300)), chunk0)
        XCTAssertEqual(out.subdata(in: o1..<(o1 + 300)), chunk1)
        // Existing atoms survive, including the non-ASCII ©cmt type and the other freeform atom.
        let ilst = moov.child("udta")!.child("meta")!.child("ilst")!
        XCTAssertEqual(ilst.children!.map(\.type), ["©cmt", "----", "----"])
        let ffs = try MP4Atoms.readFreeform(url)
        XCTAssertEqual(ffs.count, 2)
        XCTAssertEqual(ffs.first { $0.name == "markersv2" }?.text, String(repeating: "A", count: 150))
        XCTAssertEqual(ffs.first { $0.name == "thing" }?.text, "keep")

        // Replacing with a shorter value shrinks the file and moves offsets back.
        try MP4Atoms.writeFreeform(url, set: [MP4Atoms.Freeform(mean: "com.serato.dj", name: "markersv2", text: "B")])
        let out2 = try Data(contentsOf: url)
        let file2 = try MP4Atoms.parseFile(out2)
        let stco2 = file2.atoms.first { $0.type == "moov" }!.child("trak")!.child("mdia")!.child("minf")!.child("stbl")!.child("stco")!
        let p0 = MP4Atoms.be32(stco2.payload, 8)
        XCTAssertEqual(out2.subdata(in: p0..<(p0 + 300)), chunk0)
        XCTAssertEqual(try MP4Atoms.readFreeform(url).count, 2)
        // Removal.
        try MP4Atoms.writeFreeform(url, set: [], remove: [("com.serato.dj", "markersv2")])
        XCTAssertEqual(try MP4Atoms.readFreeform(url).map(\.name), ["thing"])
    }
}
