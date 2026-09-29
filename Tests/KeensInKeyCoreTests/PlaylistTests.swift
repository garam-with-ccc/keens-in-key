import XCTest
@testable import KeensInKeyCore

final class PlaylistTests: XCTestCase {
    let t1 = UUID(), t2 = UUID(), t3 = UUID(), t4 = UUID()
    let vocal = MusicTag(name: "Vocal"), peak = MusicTag(name: "Peak time"), dark = MusicTag(name: "Dark")

    func facts() -> [TrackFacts] {
        [
            TrackFacts(id: t1, title: "Alpha", artist: "A", genre: "House", key: MusicalKey.parse("8A"), bpm: 124, energy: 6, tagIds: [vocal.id, peak.id], addedAt: Date(timeIntervalSince1970: 1), analyzed: true),
            TrackFacts(id: t2, title: "Beta", artist: "B", genre: "Techno", key: MusicalKey.parse("9A"), bpm: 130, energy: 8, tagIds: [peak.id, dark.id], addedAt: Date(timeIntervalSince1970: 2), analyzed: true),
            TrackFacts(id: t3, title: "Gamma", artist: "C", genre: "Deep House", key: MusicalKey.parse("3B"), bpm: 118, energy: 4, tagIds: [vocal.id], addedAt: Date(timeIntervalSince1970: 3), analyzed: true),
            TrackFacts(id: t4, title: "Delta", artist: "D", genre: "", key: nil, bpm: nil, energy: nil, tagIds: [], addedAt: Date(timeIntervalSince1970: 4), analyzed: false),
        ]
    }

    func testTagFilter() {
        var f = TagFilter(tagIds: [vocal.id, peak.id], match: .all)
        XCTAssertTrue(f.matches([vocal.id, peak.id, dark.id]))
        XCTAssertFalse(f.matches([vocal.id]))
        f.match = .any
        XCTAssertTrue(f.matches([vocal.id]))
        XCTAssertFalse(f.matches([dark.id]))
        XCTAssertTrue(TagFilter().matches([]))
    }

    func testSmartRules() {
        var r = SmartRules()
        r.tags = TagFilter(tagIds: [peak.id], match: .all)
        r.minEnergy = 7
        XCTAssertEqual(r.apply(to: facts()).map(\.title), ["Beta"])

        var c = SmartRules()
        c.compatibleWith = MusicalKey.parse("8A")
        c.sort = .bpmAscending
        XCTAssertEqual(c.apply(to: facts()).map(\.title), ["Alpha", "Beta"])   // 8A and 9A

        var g = SmartRules()
        g.genreContains = "house"
        g.sort = .title
        g.limit = 1
        XCTAssertEqual(g.apply(to: facts()).map(\.title), ["Alpha"])

        var all = SmartRules()
        all.analyzedOnly = false
        XCTAssertEqual(all.apply(to: facts()).count, 4)
        XCTAssertEqual(all.apply(to: facts()).first?.title, "Delta")          // newest first
        var bpm = SmartRules()
        bpm.minBPM = 120; bpm.maxBPM = 125
        XCTAssertEqual(bpm.apply(to: facts()).map(\.title), ["Alpha"])
        var text = SmartRules()
        text.textContains = "gam"
        XCTAssertEqual(text.apply(to: facts()).map(\.title), ["Gamma"])
        XCTAssertTrue(SmartRules().isEmpty)
        XCTAssertFalse(text.isEmpty)
    }

    func testTreeOperations() {
        var nodes: [PlaylistNode] = []
        let col = PlaylistNode(name: "Wedding", emoji: "💍", kind: .folder)
        PlaylistTree.insert(col, under: nil, in: &nodes)
        let warm = PlaylistNode(name: "Warm-up", kind: .playlist, trackIds: [t1, t3])
        let peakList = PlaylistNode(name: "Peak", kind: .playlist, trackIds: [t2, t1])
        XCTAssertTrue(PlaylistTree.insert(warm, under: col.id, in: &nodes))
        XCTAssertTrue(PlaylistTree.insert(peakList, under: col.id, in: &nodes))
        XCTAssertFalse(PlaylistTree.insert(warm, under: UUID(), in: &nodes))
        XCTAssertEqual(PlaylistTree.find(col.id, in: nodes)?.children.count, 2)
        XCTAssertEqual(PlaylistTree.path(to: peakList.id, in: nodes), [col.id, peakList.id])
        XCTAssertEqual(PlaylistTree.manualTrackIds(of: PlaylistTree.find(col.id, in: nodes)!), [t1, t3, t2])   // union, first occurrence order

        // nested playlist inside a playlist
        let sub = PlaylistNode(name: "Acapellas", kind: .playlist, trackIds: [t4])
        XCTAssertTrue(PlaylistTree.insert(sub, under: warm.id, in: &nodes))
        XCTAssertEqual(PlaylistTree.path(to: sub.id, in: nodes)?.count, 3)
        // move up to top level, refuse cycles
        XCTAssertFalse(PlaylistTree.move(col.id, under: sub.id, in: &nodes))
        XCTAssertTrue(PlaylistTree.move(sub.id, under: nil, in: &nodes))
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(PlaylistTree.find(warm.id, in: nodes)?.children.count, 0)

        PlaylistTree.update(warm.id, in: &nodes) { $0.emoji = "🔥"; $0.trackIds.append(t2) }
        XCTAssertEqual(PlaylistTree.find(warm.id, in: nodes)?.displayName, "🔥 Warm-up")
        PlaylistTree.purgeTrack(t1, from: &nodes)
        XCTAssertEqual(PlaylistTree.find(warm.id, in: nodes)?.trackIds, [t3, t2])
        XCTAssertEqual(PlaylistTree.find(peakList.id, in: nodes)?.trackIds, [t2])
        XCTAssertNotNil(PlaylistTree.remove(peakList.id, from: &nodes))
        XCTAssertNil(PlaylistTree.find(peakList.id, in: nodes))
        XCTAssertEqual(PlaylistTree.allNodes(nodes).count, 3)
    }

    func testResolver() {
        let fs = facts()
        let byId = Dictionary(uniqueKeysWithValues: fs.map { ($0.id, $0) })
        var smart = SmartRules(); smart.tags = TagFilter(tagIds: [vocal.id])
        smart.sort = .title
        let folder = PlaylistNode(name: "Col", kind: .folder, children: [
            PlaylistNode(name: "Manual", kind: .playlist, trackIds: [t2, UUID(), t1]),
            PlaylistNode(name: "Smart", kind: .smart, rules: smart),
        ])
        XCTAssertEqual(PlaylistResolver.trackIds(of: folder.children[0], facts: byId, allFacts: fs), [t2, t1])   // dangling id dropped
        XCTAssertEqual(PlaylistResolver.trackIds(of: folder.children[1], facts: byId, allFacts: fs), [t1, t3])
        XCTAssertEqual(PlaylistResolver.trackIds(of: folder, facts: byId, allFacts: fs), [t2, t1, t3])
    }

    func testCodableRoundTrip() throws {
        var smart = SmartRules(); smart.keys = [MusicalKey.parse("8A")!]; smart.maxBPM = 128
        let node = PlaylistNode(name: "N", emoji: "🎧", kind: .folder, children: [PlaylistNode(name: "S", kind: .smart, rules: smart)])
        let data = try JSONEncoder().encode([node])
        let back = try JSONDecoder().decode([PlaylistNode].self, from: data)
        XCTAssertEqual(back, [node])
        let cats = try JSONDecoder().decode([TagCategory].self, from: JSONEncoder().encode(TagCategory.defaults))
        XCTAssertEqual(cats.map(\.name), ["Genre", "Components", "Situation", "Mood"])
    }

    func testExportersWithPlaylistTrees() throws {
        let key = KeyEstimate(key: MusicalKey.parse("8A")!, confidence: 1, strength: 1, tuning: 0, chroma: [], candidates: [])
        let tempo = TempoEstimate(bpm: 124, confidence: 1, beats: [0.5, 0.98], downbeatPhase: 0, candidates: [])
        let r = AnalysisResult(duration: 200, key: key, tempo: tempo, energy: 6, energyScore: 0.6, loudnessDb: -10, cuePoints: [], waveform: [], energyCurve: [])
        let tracks = (0..<3).map { ExportTrack(url: URL(fileURLWithPath: "/m/t\($0).mp3"), title: "T\($0)", artist: "A", result: r) }
        let tree = [ExportPlaylist(name: "Wedding", isFolder: true, children: [
            ExportPlaylist(name: "Warm-up", trackIndexes: [2, 0]),
            ExportPlaylist(name: "Peak", trackIndexes: [1]),
        ])]
        let xml = Exporters.rekordboxXML(tracks, playlists: tree)
        XCTAssertTrue(xml.contains("<NODE Type=\"0\" Name=\"Wedding\" Count=\"2\">"))
        XCTAssertTrue(xml.contains("<NODE Name=\"Warm-up\" Type=\"1\" KeyType=\"0\" Entries=\"2\">"))
        XCTAssertTrue(xml.contains("<TRACK Key=\"3\"/>"))
        XCTAssertTrue(XMLParser(data: xml.data(using: .utf8)!).parse())
        let nml = TraktorNML.export(tracks, playlists: tree)
        XCTAssertTrue(nml.contains("<NODE TYPE=\"FOLDER\" NAME=\"Wedding\"><SUBNODES COUNT=\"2\">"))
        XCTAssertTrue(nml.contains("<NODE TYPE=\"PLAYLIST\" NAME=\"Peak\"><PLAYLIST ENTRIES=\"1\""))
        XCTAssertTrue(XMLParser(data: nml.data(using: .utf8)!).parse())
    }
}
