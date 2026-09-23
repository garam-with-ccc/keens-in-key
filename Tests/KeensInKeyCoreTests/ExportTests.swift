import XCTest
@testable import KeensInKeyCore

final class ExportTests: XCTestCase {
    func sample() -> [ExportTrack] {
        let key = KeyEstimate(key: MusicalKey.parse("8A")!, confidence: 0.8, strength: 0.9, tuning: 0, chroma: [], candidates: [])
        let tempo = TempoEstimate(bpm: 128.004, confidence: 0.9, beats: [0.5, 0.96875, 1.4375, 1.90625, 2.375], downbeatPhase: 1, candidates: [])
        let cues = [CuePoint(slot: 1, name: "Intro", kind: .intro, time: 0.96875, bar: 1, energy: 5),
                    CuePoint(slot: 2, name: "Drop", kind: .drop, time: 30.5, bar: 17, energy: 8)]
        let r = AnalysisResult(duration: 245.3, key: key, tempo: tempo, energy: 7, energyScore: 0.7, loudnessDb: -10, cuePoints: cues, waveform: [], energyCurve: [])
        return [
            ExportTrack(url: URL(fileURLWithPath: "/Users/dj/Music/Artist - Song, \"Live\".mp3"), title: "Song, \"Live\"", artist: "Artist & Co", album: "LP", genre: "House", fileSize: 1234, result: r),
            ExportTrack(url: URL(fileURLWithPath: "/Users/dj/Music/untagged.wav"), title: "untagged", artist: "", result: nil),
        ]
    }

    func testCSV() {
        let csv = Exporters.csv(sample(), notation: .camelot)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("Artist,Title,Key,"))
        XCTAssertTrue(lines[1].contains("\"Song, \"\"Live\"\"\""))
        XCTAssertTrue(lines[1].contains(",8A,8A,Am,1m,128.00,7,4:05,"))
        XCTAssertTrue(lines[2].hasPrefix(",untagged,,,,,,,,,"))
    }

    func testRekordboxXML() throws {
        let xml = Exporters.rekordboxXML(sample(), playlistName: "Set", notation: .camelot, appVersion: "1.2")
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<DJ_PLAYLISTS Version=\"1.0.0\">"))
        XCTAssertTrue(xml.contains("<COLLECTION Entries=\"2\">"))
        XCTAssertTrue(xml.contains("Tonality=\"8A\""))
        XCTAssertTrue(xml.contains("AverageBpm=\"128.00\""))
        XCTAssertTrue(xml.contains("<TEMPO Inizio=\"0.969\" Bpm=\"128.00\" Metro=\"4/4\" Battito=\"1\"/>"))
        XCTAssertTrue(xml.contains("<POSITION_MARK Name=\"Drop\" Type=\"0\" Start=\"30.500\" Num=\"1\"/>"))
        XCTAssertTrue(xml.contains("Location=\"file://localhost/Users/dj/Music/Artist%20-%20Song,%20%22Live%22.mp3\""))
        XCTAssertTrue(xml.contains("Artist=\"Artist &amp; Co\""))
        XCTAssertTrue(xml.contains("<NODE Name=\"Set\" Type=\"1\" KeyType=\"0\" Entries=\"2\">"))
        // Well-formed XML.
        let parser = XMLParser(data: xml.data(using: .utf8)!)
        XCTAssertTrue(parser.parse(), "rekordbox XML should parse: \(String(describing: parser.parserError))")
    }

    func testM3U() {
        let m3u = Exporters.m3u(sample())
        XCTAssertTrue(m3u.hasPrefix("#EXTM3U\n#EXTINF:245,8A Artist & Co - Song, \"Live\"\n/Users/dj/Music/Artist - Song, \"Live\".mp3\n"))
    }
}
