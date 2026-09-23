import XCTest
@testable import KeensInKeyCore

/// End-to-end analysis on synthesised signals with known ground truth.
final class AnalyzerTests: XCTestCase {
    static let sampleRate = 44100.0

    /// Chord loop (one bar per chord) with a kick on every beat, hats on off-beats and a bass line.
    static func synthesize(bpm: Double, chords: [[Int]], seconds: Double = 24, drums: Bool = true) -> [Float] {
        let sr = sampleRate
        let n = Int(seconds * sr)
        var y = [Double](repeating: 0, count: n)
        let beat = 60.0 / bpm
        let bar = 4 * beat
        func freq(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
        var b = 0
        while Double(b) * bar < seconds {
            let chord = chords[b % chords.count]
            let s0 = Int(Double(b) * bar * sr), s1 = min(n, Int(Double(b + 1) * bar * sr))
            if s0 >= n { break }
            for i in s0..<s1 {
                let t = Double(i - s0) / sr
                let env = min(1, t * 50) * exp(-t * 0.5)
                var v = 0.0
                for m in chord {
                    let f = freq(m)
                    var h = 1
                    while Double(h) * f < 8000 && h < 8 { v += sin(2 * .pi * f * Double(h) * t) / Double(h); h += 1 }
                }
                y[i] += 0.08 * v * env
                // bass on beats 1 and 3 plus the "and" of 2 (a typical syncopated pop bass line)
                let barPos = t.truncatingRemainder(dividingBy: bar)
                let hits = [0.0, 1.5 * beat, 2 * beat]
                if let last = hits.filter({ $0 <= barPos }).last {
                    y[i] += 0.3 * sin(2 * .pi * freq(chord.min()! - 12) * t) * exp(-(barPos - last) * 6)
                }
            }
            b += 1
        }
        if drums {
            var k = 0
            while Double(k) * beat < seconds {
                let s0 = Int(Double(k) * beat * sr)
                for i in 0..<Int(0.12 * sr) where s0 + i < n {
                    let t = Double(i) / sr
                    y[s0 + i] += 0.9 * sin(2 * .pi * (50 + 90 * exp(-t * 40)) * t) * exp(-t * 20)
                }
                let h0 = s0 + Int(beat / 2 * sr)
                var seed: UInt32 = UInt32(k & 0xFFFF) &+ 7
                for i in 0..<Int(0.03 * sr) where h0 + i < n {
                    seed = seed &* 1664525 &+ 1013904223
                    let noise = Double(seed % 2000) / 1000 - 1
                    y[h0 + i] += 0.12 * noise * exp(-Double(i) / sr * 150)
                }
                if k % 2 == 1 {   // snare on beats 2 and 4
                    for i in 0..<Int(0.12 * sr) where s0 + i < n {
                        seed = seed &* 1664525 &+ 1013904223
                        let noise = Double(seed % 2000) / 1000 - 1
                        y[s0 + i] += 0.35 * noise * exp(-Double(i) / sr * 35)
                    }
                }
                k += 1
            }
        }
        let peak = y.map { abs($0) }.max() ?? 1
        return y.map { Float($0 / peak * 0.9) }
    }

    func analyze(_ samples: [Float], options: TrackAnalyzer.Options = TrackAnalyzer.Options()) throws -> AnalysisResult {
        let audio = DecodedAudio(sampleRate: AnalyzerTests.sampleRate, samples: samples, duration: Double(samples.count) / AnalyzerTests.sampleRate, sourceSampleRate: 44100, sourceChannels: 1)
        return try TrackAnalyzer(options: options).analyze(audio: audio)
    }

    func testAMinorAt128() throws {
        // Am – F – C – G
        let r = try analyze(AnalyzerTests.synthesize(bpm: 128, chords: [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]))
        XCTAssertEqual(r.key.key.camelotNumber, 8)   // A minor (8A) or its relative C major (8B): a four-chord loop is ambiguous
        XCTAssertEqual(r.tempo.bpm, 128, accuracy: 0.15)
        XCTAssertGreaterThan(r.tempo.beats.count, 40)
        XCTAssertFalse(r.cuePoints.isEmpty)
        XCTAssertEqual(r.cuePoints.first?.kind, .intro)
        XCTAssertEqual(r.waveform.count, 2000)
        XCTAssertTrue((1...10).contains(r.energy))
        // Beats are evenly spaced.
        let ibis = zip(r.tempo.beats.dropFirst(), r.tempo.beats).map { $0 - $1 }
        let median = ibis.sorted()[ibis.count / 2]
        XCTAssertEqual(median, 60.0 / 128, accuracy: 0.01)
    }

    func testFSharpMinorAt140() throws {
        let r = try analyze(AnalyzerTests.synthesize(bpm: 140, chords: [[54, 57, 61], [50, 54, 57], [57, 61, 64], [52, 56, 59]]))
        XCTAssertEqual(r.key.key.camelot, "11A")
        XCTAssertEqual(r.tempo.bpm, 140, accuracy: 0.15)
    }

    func testEFlatMajorAt95() throws {
        // Eb – Bb – Cm – Ab
        let r = try analyze(AnalyzerTests.synthesize(bpm: 95, chords: [[63, 67, 70], [58, 62, 65], [60, 63, 67], [56, 60, 63]]))
        XCTAssertEqual(r.key.key.camelotNumber, 5)   // Eb major (5B) or its relative C minor (5A)
        XCTAssertEqual(r.tempo.bpm, 95, accuracy: 0.15)
    }

    func testTempoRangeFolding() throws {
        var options = TrackAnalyzer.Options()
        options.minBPM = 100
        options.maxBPM = 200
        let r = try analyze(AnalyzerTests.synthesize(bpm: 174, chords: [[58, 62, 65], [53, 57, 60]]), options: options)
        XCTAssertEqual(r.tempo.bpm, 174, accuracy: 0.3)
        options.minBPM = 60
        options.maxBPM = 120
        let r2 = try analyze(AnalyzerTests.synthesize(bpm: 174, chords: [[58, 62, 65], [53, 57, 60]]), options: options)
        XCTAssertEqual(r2.tempo.bpm, 87, accuracy: 0.3)
    }

    func testQuantize() {
        let beats = (0..<64).map { Double($0) * 0.5 }
        let q = StructureAnalyzer.quantize(time: 10.2, beats: beats, downbeatPhase: 1, mode: .bar)
        XCTAssertEqual(q.time, 10.5, accuracy: 1e-9)   // downbeats at 0.5, 2.5, 4.5 … 10.5
        XCTAssertEqual(q.bar, 6)
        let b = StructureAnalyzer.quantize(time: 10.2, beats: beats, downbeatPhase: 1, mode: .beat)
        XCTAssertEqual(b.time, 10.0, accuracy: 1e-9)
        let off = StructureAnalyzer.quantize(time: 10.2, beats: beats, downbeatPhase: 1, mode: .off)
        XCTAssertEqual(off.time, 10.2)
        XCTAssertNil(off.bar)
        XCTAssertEqual(StructureAnalyzer.barNumber(for: 10.4, beats: beats, downbeatPhase: 1), 5)
    }

    func testSilenceDoesNotCrash() throws {
        let r = try analyze([Float](repeating: 0, count: 44100 * 3))
        XCTAssertEqual(r.energy, 1)
        XCTAssertTrue(r.tempo.beats.isEmpty || r.tempo.bpm >= 0)
    }

    func testShortFile() throws {
        let r = try analyze(AnalyzerTests.synthesize(bpm: 120, chords: [[60, 64, 67]], seconds: 1.2))
        XCTAssertEqual(r.waveform.count, 2000)
    }
}
