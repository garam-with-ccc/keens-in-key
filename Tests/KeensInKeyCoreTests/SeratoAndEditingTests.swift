import XCTest
import AVFoundation
@testable import KeensInKeyCore

final class SeratoAndEditingTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("kik-serato-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpDir) }

    func sampleResult() -> AnalysisResult {
        let key = KeyEstimate(key: MusicalKey.parse("8A")!, confidence: 0.8, strength: 0.9, tuning: 0, chroma: [], candidates: [])
        let beats = (0..<128).map { 0.5 + Double($0) * 0.46875 }   // 128 BPM from 0.5 s
        let tempo = TempoEstimate(bpm: 128, confidence: 0.9, beats: beats, downbeatPhase: 1, candidates: [])
        let cues = [CuePoint(slot: 1, name: "Intro", kind: .intro, time: beats[1], bar: 1, energy: 5),
                    CuePoint(slot: 2, name: "Drop", kind: .drop, time: beats[33], bar: 9, energy: 8)]
        return AnalysisResult(duration: 61, key: key, tempo: tempo, energy: 7, energyScore: 0.7, loudnessDb: -10, cuePoints: cues,
                              waveform: [], energyCurve: (0..<61).map { $0 < 16 ? 0.3 : 0.9 })
    }

    // MARK: Serato format

    func testMarkersRoundTripThroughGEOB() {
        let cues = [SeratoTags.Cue(index: 0, positionMs: 968, color: (0xCC, 0, 0), name: "Intro"),
                    SeratoTags.Cue(index: 3, positionMs: 15968, color: (0xCC, 0xCC, 0), name: "Drop 노래")]
        let data = SeratoTags.markersGEOBData(cues: cues)
        XCTAssertEqual(data[0], 0x01); XCTAssertEqual(data[1], 0x01)
        let text = String(decoding: data.dropFirst(2), as: UTF8.self)
        XCTAssertTrue(text.allSatisfy { $0.isLetter || $0.isNumber || "+/=\n".contains($0) })
        XCTAssertEqual(SeratoTags.parseMarkersGEOBData(data), cues)
        // Decoded payload starts with the version and a CUE entry.
        var b64 = text.replacingOccurrences(of: "\n", with: "")
        while b64.count % 4 != 0 { b64 += "=" }
        let payload = Data(base64Encoded: b64)!
        XCTAssertEqual(Array(payload.prefix(2)), [0x01, 0x01])
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("CUE"))
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("BPMLOCK"))
        XCTAssertEqual(payload.last, 0x00)
    }

    func testBeatGridRoundTrip() {
        let data = SeratoTags.beatGridGEOBData(firstBeatSeconds: 0.5, bpm: 127.98)
        XCTAssertEqual(data.count, 15)
        XCTAssertEqual(Array(data.prefix(6)), [0x01, 0x00, 0, 0, 0, 1])
        let g = SeratoTags.parseBeatGridGEOBData(data)!
        XCTAssertEqual(g.firstBeat, 0.5, accuracy: 1e-6)
        XCTAssertEqual(g.bpm, 127.98, accuracy: 1e-4)
    }

    func testContainerText() {
        let geob = SeratoTags.markersGEOBData(cues: [SeratoTags.Cue(index: 1, positionMs: 100, color: (1, 2, 3), name: "x")])
        let text = SeratoTags.containerText(name: "Serato Markers2", geobData: geob)
        let decoded = Data(base64Encoded: text)!
        XCTAssertTrue(String(decoding: decoded.prefix(24), as: UTF8.self) == "application/octet-stream")
        XCTAssertEqual(SeratoTags.geobData(fromContainerText: text, expectedName: "Serato Markers2"), geob)
        XCTAssertNil(SeratoTags.geobData(fromContainerText: text, expectedName: "Serato BeatGrid"))
    }

    func testID3GEOBFramesReplaceNotDuplicate() {
        var tag = ID3Tag(version: 3)
        tag.title = "t"
        let r = sampleResult()
        SeratoTags.apply(cues: SeratoTags.cues(from: r), firstBeat: 0.5, bpm: 128, to: &tag)
        SeratoTags.apply(cues: SeratoTags.cues(from: r), firstBeat: 0.5, bpm: 128, to: &tag)
        XCTAssertEqual(tag.frames.filter { $0.id == "GEOB" }.count, 2)
        let cues = SeratoTags.cues(in: tag)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].name, "Intro")
        XCTAssertEqual(cues[0].positionMs, Int((r.tempo.beats[1] * 1000).rounded()))
        XCTAssertEqual(cues[1].index, 1)
        XCTAssertEqual(SeratoTags.beatGrid(in: tag)?.bpm ?? 0, 128, accuracy: 0.001)
        // Encode → parse keeps GEOB frames intact.
        let parsed = try! ID3Tag.parse(tag.encode())!
        XCTAssertEqual(SeratoTags.cues(in: parsed), cues)
    }

    func makeAudio(_ url: URL, settings: [String: Any]) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050)!
        buf.frameLength = 22050
        for i in 0..<22050 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.03) * 0.4 }
        try file.write(from: buf)
    }

    func testSeratoWrittenIntoEveryContainer() async throws {
        let r = sampleResult()
        let payload = TagService.SeratoPayload(result: r)
        let wav = tmpDir.appendingPathComponent("s.wav")
        try makeAudio(wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let aiff = tmpDir.appendingPathComponent("s.aiff")
        try makeAudio(aiff, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false])
        let m4a = tmpDir.appendingPathComponent("s.m4a")
        try makeAudio(m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        // Fake MP3 and FLAC containers (tag layer only).
        let mp3 = tmpDir.appendingPathComponent("s.mp3")
        try Data((0..<3000).map { UInt8($0 % 251) }).write(to: mp3)
        let flac = tmpDir.appendingPathComponent("s.flac")
        var f = Data("fLaC".utf8); f.append(0x80); f.append(contentsOf: [0, 0, 34]); f.append(Data(count: 34)); f.append(Data(count: 500))
        try f.write(to: flac)

        for url in [wav, aiff, m4a, mp3, flac] {
            var fields = TagFields()
            fields.initialKey = "8A"; fields.bpm = "128"
            _ = try await TagService.write(fields, to: url, serato: payload)
            let cues = await TagService.readSeratoCues(url)
            XCTAssertEqual(cues.map(\.name), ["Intro", "Drop"], url.lastPathComponent)
            XCTAssertEqual(cues.map(\.index), [0, 1], url.lastPathComponent)
            let tags = await TagService.read(url)
            XCTAssertEqual(tags.initialKey, "8A", url.lastPathComponent)
            if url.pathExtension != "mp3" && url.pathExtension != "flac" {
                XCTAssertNoThrow(try AVAudioFile(forReading: url), url.lastPathComponent)
            }
        }
    }

    // MARK: Cue editing

    func testCueEditingOperations() {
        var r = sampleResult()
        let added = CueEditing.add(at: 20.1, to: &r, mode: .bar)!
        XCTAssertEqual(r.cuePoints.count, 3)
        XCTAssertEqual(added.bar, 11)                       // bars start at beats[1], 4 beats each
        XCTAssertEqual(added.time, r.tempo.beats[41], accuracy: 1e-9)
        XCTAssertEqual(r.cuePoints.map(\.slot), [1, 2, 3])
        XCTAssertEqual(r.cuePoints[2].id, added.id)

        CueEditing.nudge(added.id, beats: -1, in: &r)
        XCTAssertEqual(r.cuePoints[2].time, r.tempo.beats[40], accuracy: 1e-9)
        XCTAssertEqual(r.cuePoints[2].bar, 10)

        CueEditing.move(added.id, to: 5.0, in: &r, mode: .beat)
        XCTAssertEqual(r.cuePoints.map(\.name)[1], added.name)   // re-sorted by time
        CueEditing.rename(added.id, to: "Vocal", in: &r)
        CueEditing.setKind(r.cuePoints[0].id, .build, in: &r)
        XCTAssertEqual(r.cuePoints[0].name, "Build")            // default name follows the kind
        XCTAssertEqual(r.cuePoints.first { $0.id == added.id }?.name, "Vocal")

        CueEditing.snapAll(in: &r, mode: .bar)
        for c in r.cuePoints { XCTAssertNotNil(c.bar) }

        CueEditing.delete(added.id, in: &r)
        XCTAssertEqual(r.cuePoints.count, 2)
        XCTAssertEqual(r.cuePoints.map(\.slot), [1, 2])

        // Slots are capped.
        for i in 0..<10 { _ = CueEditing.add(at: Double(i) * 3 + 1, to: &r, mode: .off) }
        XCTAssertEqual(r.cuePoints.count, 8)
    }

    func testDownbeatShiftAndTempoScaling() {
        var r = sampleResult()
        XCTAssertEqual(r.cuePoints[1].bar, 9)
        CueEditing.shiftDownbeat(by: 1, in: &r)
        XCTAssertEqual(r.tempo.downbeatPhase, 2)
        XCTAssertEqual(r.cuePoints[1].bar, 8)                    // beats[33] is now bar 8 (bars start at beat 2)
        CueEditing.shiftDownbeat(by: -1, in: &r)
        XCTAssertEqual(r.tempo.downbeatPhase, 1)

        let beatsBefore = r.tempo.beats.count
        CueEditing.scaleTempo(by: 0.5, in: &r)
        XCTAssertEqual(r.tempo.bpm, 64)
        XCTAssertEqual(r.tempo.beats.count, beatsBefore / 2)
        XCTAssertEqual(r.tempo.beats[0], 0.5 + 0.46875, accuracy: 1e-9)   // keeps the downbeat phase parity
        CueEditing.scaleTempo(by: 2, in: &r)
        XCTAssertEqual(r.tempo.bpm, 128)
        XCTAssertEqual(r.tempo.beats.count, beatsBefore - 1)
        CueEditing.setKey(MusicalKey.parse("5B")!, in: &r)
        XCTAssertEqual(r.key.key.camelot, "5B")
        XCTAssertEqual(r.key.confidence, 1)
    }

    // MARK: Traktor

    func testTraktorNML() throws {
        let r = sampleResult()
        let t = ExportTrack(url: URL(fileURLWithPath: "/Users/dj/Music/Set/Track & One.mp3"), title: "Track & One", artist: "A", album: "B", genre: "House", fileSize: 4096, result: r)
        let xml = TraktorNML.export([t], playlistName: "Test")
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<NML VERSION=\"19\">"))
        XCTAssertTrue(xml.contains("<LOCATION DIR=\"/:Users/:dj/:Music/:Set/:\" FILE=\"Track &amp; One.mp3\""))
        XCTAssertTrue(xml.contains("<TEMPO BPM=\"128.000000\" BPM_QUALITY=\"100.000000\">"))
        XCTAssertTrue(xml.contains("<MUSICAL_KEY VALUE=\"21\">"))            // A minor = 12 + 9
        XCTAssertTrue(xml.contains("KEY=\"1m\""))
        XCTAssertTrue(xml.contains("TYPE=\"4\""))                              // grid marker
        XCTAssertTrue(xml.contains("<CUE_V2 NAME=\"Drop\" DISPL_ORDER=\"0\" TYPE=\"0\" START=\"\(String(format: "%.6f", r.cuePoints[1].time * 1000))\" LEN=\"0.000000\" REPEATS=\"-1\" HOTCUE=\"1\">"))
        XCTAssertTrue(xml.contains("<PLAYLIST ENTRIES=\"1\""))
        let parser = XMLParser(data: xml.data(using: .utf8)!)
        XCTAssertTrue(parser.parse(), String(describing: parser.parserError))
        XCTAssertEqual(TraktorNML.musicalKeyValue(MusicalKey.parse("8B")!), 0)   // C major
        XCTAssertEqual(TraktorNML.musicalKeyValue(MusicalKey.parse("1A")!), 20)  // Ab minor
    }

    func testRekordboxCueColours() {
        let r = sampleResult()
        let t = ExportTrack(url: URL(fileURLWithPath: "/x/y.mp3"), title: "y", artist: "", result: r)
        let xml = Exporters.rekordboxXML([t])
        XCTAssertTrue(xml.contains("Name=\"Drop\" Type=\"0\" Start=\"\(String(format: "%.3f", r.cuePoints[1].time))\" Num=\"1\" Red=\"230\" Green=\"40\" Blue=\"40\"/>"))
        XCTAssertTrue(XMLParser(data: xml.data(using: .utf8)!).parse())
    }
}
