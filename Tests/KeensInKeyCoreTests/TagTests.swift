import XCTest
import AVFoundation
@testable import KeensInKeyCore

final class TagTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("kik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testID3EncodeParseRoundTrip() throws {
        for version: UInt8 in [3, 4] {
            var tag = ID3Tag(version: version)
            tag.title = "Тест 노래 ✓"
            tag.artist = "Artist"
            tag.initialKey = "8A"
            tag.bpm = "128"
            tag.grouping = "8A"
            tag.setComment("8A - Energy 7 - hello")
            tag.setUserText("ENERGYLEVEL", "7")
            let data = tag.encode(padding: 100)
            XCTAssertEqual(ID3Tag.tagLength(in: data), data.count)
            let parsed = try XCTUnwrap(try ID3Tag.parse(data))
            XCTAssertEqual(parsed.version, version)
            XCTAssertEqual(parsed.title, "Тест 노래 ✓")
            XCTAssertEqual(parsed.artist, "Artist")
            XCTAssertEqual(parsed.initialKey, "8A")
            XCTAssertEqual(parsed.bpm, "128")
            XCTAssertEqual(parsed.grouping, "8A")
            XCTAssertEqual(parsed.comment(), "8A - Energy 7 - hello")
            XCTAssertEqual(parsed.userText("ENERGYLEVEL"), "7")
        }
    }

    func testMP3WriteInPlaceAndGrow() throws {
        // A fake MP3: an ID3 tag with small padding followed by "audio" bytes.
        var tag = ID3Tag(version: 3)
        tag.title = "Song"
        let audio = Data((0..<5000).map { UInt8($0 % 251) })
        let url = tmpDir.appendingPathComponent("a.mp3")
        var file = tag.encode(padding: 16)
        file.append(audio)
        try file.write(to: url)

        // Fits in place.
        var t2 = try XCTUnwrap(try ID3File.readMP3(url).tag)
        t2.initialKey = "8A"
        try ID3File.writeMP3(t2, to: url)
        var d = try Data(contentsOf: url)
        XCTAssertEqual(d.count, file.count)
        XCTAssertEqual(d.suffix(5000), audio)
        XCTAssertEqual(try ID3File.readMP3(url).tag?.initialKey, "8A")

        // Needs to grow -> rewrite.
        var t3 = try XCTUnwrap(try ID3File.readMP3(url).tag)
        t3.setComment(String(repeating: "x", count: 500))
        try ID3File.writeMP3(t3, to: url)
        d = try Data(contentsOf: url)
        XCTAssertGreaterThan(d.count, file.count)
        XCTAssertEqual(d.suffix(5000), audio)
        let t4 = try XCTUnwrap(try ID3File.readMP3(url).tag)
        XCTAssertEqual(t4.comment()?.count, 500)
        XCTAssertEqual(t4.title, "Song")
        XCTAssertEqual(t4.initialKey, "8A")

        // File without a tag gets one prepended.
        let bare = tmpDir.appendingPathComponent("bare.mp3")
        try audio.write(to: bare)
        var t5 = ID3Tag(version: 3)
        t5.initialKey = "5B"
        try ID3File.writeMP3(t5, to: bare)
        XCTAssertEqual(try ID3File.readMP3(bare).tag?.initialKey, "5B")
        XCTAssertEqual(try Data(contentsOf: bare).suffix(5000), audio)
    }

    func makeWave(_ url: URL, settings: [String: Any], seconds: Double = 0.5) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44100 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) { buf.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.5 }
        try file.write(from: buf)
    }

    func testWAVAndAIFFChunkWrite() async throws {
        let wav = tmpDir.appendingPathComponent("t.wav")
        try makeWave(wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let aiff = tmpDir.appendingPathComponent("t.aiff")
        try makeWave(aiff, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false])
        for url in [wav, aiff] {
            let before = try AVAudioFile(forReading: url).length
            var fields = TagFields()
            fields.initialKey = "8A"; fields.bpm = "128"; fields.comment = "8A - Energy 6"; fields.title = "Chunky"
            _ = try await TagService.write(fields, to: url)
            let read = await TagService.read(url)
            XCTAssertEqual(read.initialKey, "8A", url.lastPathComponent)
            XCTAssertEqual(read.bpm, "128")
            XCTAssertEqual(read.comment, "8A - Energy 6")
            XCTAssertEqual(read.title, "Chunky")
            // Still decodable with the same length.
            let after = try AVAudioFile(forReading: url).length
            XCTAssertEqual(before, after, url.lastPathComponent)
            // Second write replaces rather than duplicates.
            fields.initialKey = "9A"
            _ = try await TagService.write(fields, to: url)
            let again = await TagService.read(url)
            XCTAssertEqual(again.initialKey, "9A")
            XCTAssertEqual(try AVAudioFile(forReading: url).length, before)
        }
    }

    func testM4AWrite() async throws {
        let url = tmpDir.appendingPathComponent("t.m4a")
        try makeWave(url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1], seconds: 1.0)
        var fields = TagFields()
        fields.initialKey = "11B"; fields.bpm = "124"; fields.comment = "11B - Energy 8"; fields.grouping = "11B"; fields.title = "AAC Song"; fields.artist = "Someone"
        _ = try await TagService.write(fields, to: url)
        let read = await TagService.read(url)
        XCTAssertEqual(read.initialKey, "11B")
        XCTAssertEqual(read.bpm, "124")
        XCTAssertEqual(read.comment, "11B - Energy 8")
        XCTAssertEqual(read.grouping, "11B")
        XCTAssertEqual(read.title, "AAC Song")
        XCTAssertEqual(read.artist, "Someone")
        XCTAssertNoThrow(try AVAudioFile(forReading: url))
    }

    func testFLACWrite() throws {
        // Minimal FLAC: marker + STREAMINFO (34 bytes) + fake audio.
        var d = Data("fLaC".utf8)
        d.append(0x80); d.append(contentsOf: [0, 0, 34])
        var si = [UInt8](repeating: 0, count: 34)
        si[10] = 0x0A; si[11] = 0xC4; si[12] = 0x42   // 44100 Hz, 2 ch
        d.append(contentsOf: si)
        let audio = Data((0..<3000).map { UInt8(($0 * 7) % 256) })
        d.append(audio)
        let url = tmpDir.appendingPathComponent("t.flac")
        try d.write(to: url)
        XCTAssertNil(try FLACFile.readComment(url))

        var vc = VorbisComment()
        vc.set("TITLE", "Flac Song"); vc.set("INITIALKEY", "3A"); vc.set("BPM", "140")
        try FLACFile.writeComment(vc, to: url)
        let read = try XCTUnwrap(try FLACFile.readComment(url))
        XCTAssertEqual(read.first("title"), "Flac Song")
        XCTAssertEqual(read.first("INITIALKEY"), "3A")
        XCTAssertEqual(try Data(contentsOf: url).suffix(3000), audio)
        let sizeAfterGrow = try Data(contentsOf: url).count

        // Smaller change fits in place (padding absorbs it).
        var vc2 = read
        vc2.set("INITIALKEY", "4A")
        try FLACFile.writeComment(vc2, to: url)
        XCTAssertEqual(try Data(contentsOf: url).count, sizeAfterGrow)
        XCTAssertEqual(try FLACFile.readComment(url)?.first("INITIALKEY"), "4A")
        XCTAssertEqual(try Data(contentsOf: url).suffix(3000), audio)
        let info = try XCTUnwrap(FLACFile.streamInfo(url))
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.channels, 2)
    }

    func testStripPreviousTag() {
        XCTAssertEqual(TagService.stripPreviousTag("8A - Energy 7 - my comment"), "my comment")
        XCTAssertEqual(TagService.stripPreviousTag("8A - Energy 7"), "")
        XCTAssertEqual(TagService.stripPreviousTag("8A - my comment"), "my comment")
        XCTAssertEqual(TagService.stripPreviousTag("my comment"), "my comment")
        XCTAssertEqual(TagService.stripPreviousTag("Am - Energy 3 - x"), "x")
        XCTAssertEqual(TagService.stripPreviousTag("Amazing track"), "Amazing track")
    }

    func testCommentFormatting() {
        var opts = TagWritingOptions()
        let key = MusicalKey.parse("8A")!
        XCTAssertEqual(opts.expand(opts.commentFormat, key: key, energy: 7, bpm: 128.4, title: "T", artist: "A"), "8A - Energy 7")
        opts.notation = .openKey
        opts.bpmDecimals = 1
        XCTAssertEqual(opts.expand("{key} {bpm} {traditional}", key: key, energy: 7, bpm: 128.44, title: "T", artist: "A"), "1m 128.4 Am")
    }
}
