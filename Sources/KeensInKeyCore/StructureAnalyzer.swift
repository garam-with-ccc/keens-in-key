import Foundation
import Accelerate

/// Beat-level and bar-level features used for downbeat estimation, energy and cue points.
public struct BeatFeatures: Sendable {
    /// Per beat: total energy in dB.
    public var energyDb: [Float]
    public var lowDb: [Float]
    public var highDb: [Float]
    /// Per beat: L1-normalised chroma (12).
    public var chroma: [[Float]]
}

public enum StructureAnalyzer {
    /// Aggregates frame-level features into beat-level features.
    public static func beatFeatures(beats: [Double], bands: BandEnergies, frameRate: Double,
                                    chromagram: [[Float]], chromaFrameDuration: Double, duration: Double) -> BeatFeatures {
        let nb = beats.count
        var energy = [Float](repeating: -80, count: nb)
        var low = [Float](repeating: -80, count: nb)
        var high = [Float](repeating: -80, count: nb)
        var chroma = [[Float]](repeating: [Float](repeating: 1.0 / 12, count: 12), count: nb)
        let nFrames = bands.total.count
        let nChroma = chromagram.count
        for i in 0..<nb {
            let t0 = beats[i]
            let t1 = i + 1 < nb ? beats[i + 1] : min(duration, t0 + (i > 0 ? t0 - beats[i - 1] : 0.5))
            let f0 = max(0, min(nFrames - 1, Int(t0 * frameRate)))
            let f1 = max(f0 + 1, min(nFrames, Int(t1 * frameRate)))
            var e: Float = 0, l: Float = 0, h: Float = 0
            let count = Float(f1 - f0)
            bands.total.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + f0, 1, &e, vDSP_Length(f1 - f0)) }
            bands.low.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + f0, 1, &l, vDSP_Length(f1 - f0)) }
            bands.high.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + f0, 1, &h, vDSP_Length(f1 - f0)) }
            energy[i] = 10 * log10f(max(e / count, 1e-12))
            low[i] = 10 * log10f(max(l / count, 1e-12))
            high[i] = 10 * log10f(max(h / count, 1e-12))
            if nChroma > 0 {
                let c0 = max(0, min(nChroma - 1, Int(t0 / chromaFrameDuration)))
                let c1 = max(c0 + 1, min(nChroma, Int(t1 / chromaFrameDuration)))
                var acc = [Float](repeating: 0, count: 12)
                for c in c0..<c1 { for k in 0..<12 { acc[k] += chromagram[c][k] } }
                let s = acc.reduce(0, +)
                if s > 0 { chroma[i] = acc.map { $0 / s } }
            }
        }
        return BeatFeatures(energyDb: energy, lowDb: low, highDb: high, chroma: chroma)
    }

    /// Feature vector per beat used for novelty measurements.
    static func featureVectors(_ f: BeatFeatures) -> [[Float]] {
        let n = f.energyDb.count
        guard n > 0 else { return [] }
        func norm(_ x: [Float]) -> [Float] {
            let m = DSP.mean(x), s = max(DSP.std(x), 1e-3)
            return x.map { DSP.clamp(($0 - m) / s, -3, 3) / 3 }
        }
        let e = norm(f.energyDb), l = norm(f.lowDb), h = norm(f.highDb)
        var out = [[Float]]()
        out.reserveCapacity(n)
        for i in 0..<n {
            var v: [Float] = [e[i] * 1.5, l[i], h[i]]
            v.append(contentsOf: f.chroma[i].map { $0 * 2.5 })
            out.append(v)
        }
        return out
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var acc: Float = 0
        for i in 0..<min(a.count, b.count) { let d = a[i] - b[i]; acc += d * d }
        return sqrt(acc)
    }

    static func meanVector(_ vs: ArraySlice<[Float]>) -> [Float] {
        guard let first = vs.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for v in vs { for i in 0..<acc.count { acc[i] += v[i] } }
        let n = Float(vs.count)
        return acc.map { $0 / n }
    }

    /// Chooses which beat phase (0…3) carries the downbeats: the phase whose beats
    /// most often coincide with changes in energy / harmony between consecutive bars.
    public static func downbeatPhase(features: BeatFeatures) -> Int {
        let vecs = featureVectors(features)
        let n = vecs.count
        guard n >= 12 else { return 0 }
        var scores = [Double](repeating: 0, count: 4)
        var counts = [Double](repeating: 0, count: 4)
        for i in 4..<(n - 4) {
            let before = meanVector(vecs[(i - 4)..<i])
            let after = meanVector(vecs[i..<(i + 4)])
            let d = Double(distance(before, after))
            // Kick emphasis: downbeats tend to carry strong low-frequency onsets.
            let lowJump = Double(max(0, features.lowDb[i] - features.lowDb[i - 1]))
            scores[i % 4] += d + 0.02 * lowJump
            counts[i % 4] += 1
        }
        var best = 0
        var bestV = -Double.infinity
        for p in 0..<4 where counts[p] > 0 {
            let v = scores[p] / counts[p]
            if v > bestV { bestV = v; best = p }
        }
        return best
    }

    // MARK: Cue points

    public struct CueConfig: Sendable {
        public var maxCues: Int = 8
        public var kernelBars: Int = 4
        public var minSpacingBars: Int = 4
        public init() {}
    }

    /// Detects section boundaries on the bar grid and labels them as cue points.
    public static func detectCues(beats: [Double], downbeatPhase: Int, features: BeatFeatures,
                                  duration: Double, trackEnergy: Int, config: CueConfig = CueConfig()) -> [CuePoint] {
        let n = beats.count
        guard n >= 8 else {
            return beats.isEmpty ? [] : [CuePoint(slot: 1, name: "Intro", kind: .intro, time: beats[0], bar: 1, energy: trackEnergy)]
        }
        let phase = min(downbeatPhase, n - 1)
        let barStarts = Array(stride(from: phase, to: n, by: 4))   // beat index of each bar
        let bars = barStarts.count
        guard bars >= 4 else {
            return [CuePoint(slot: 1, name: "Intro", kind: .intro, time: beats[phase], bar: 1, energy: trackEnergy)]
        }
        let vecs = featureVectors(features)
        var barVecs = [[Float]]()
        var barEnergy = [Float]()
        for b in 0..<bars {
            let s = barStarts[b]
            let e = min(n, s + 4)
            barVecs.append(meanVector(vecs[s..<e]))
            barEnergy.append(features.energyDb[s..<e].reduce(0, +) / Float(e - s))
        }

        // Novelty at each bar boundary.
        let k = config.kernelBars
        var novelty = [Float](repeating: 0, count: bars)
        if bars > 2 * k {
            for b in k...(bars - k) where b < bars {
                let before = meanVector(barVecs[(b - k)..<b])
                let after = meanVector(barVecs[b..<min(bars, b + k)])
                novelty[b] = distance(before, after)
            }
        }
        let nMean = DSP.mean(novelty), nStd = DSP.std(novelty)
        let threshold = nMean + 0.25 * nStd

        var peaks: [(bar: Int, score: Float)] = []
        for b in 1..<(bars - 1) where novelty[b] >= novelty[b - 1] && novelty[b] > novelty[b + 1] && novelty[b] > threshold {
            var score = novelty[b]
            if b % 8 == 0 { score *= 1.3 } else if b % 4 == 0 { score *= 1.12 } else if b % 2 == 0 { score *= 1.03 }
            peaks.append((b, score))
        }
        peaks.sort { $0.score > $1.score }
        var chosen: [Int] = [0]
        for p in peaks {
            if chosen.count >= config.maxCues { break }
            if chosen.contains(where: { abs($0 - p.bar) < config.minSpacingBars }) { continue }
            chosen.append(p.bar)
        }
        chosen.sort()

        // Section energies and labels.
        let sectionEnergy: [Float] = (0..<chosen.count).map { i in
            let s = chosen[i], e = i + 1 < chosen.count ? chosen[i + 1] : bars
            return barEnergy[s..<max(s + 1, e)].reduce(0, +) / Float(max(1, e - s))
        }
        let trackMean = DSP.mean(barEnergy)
        let maxE = sectionEnergy.max() ?? trackMean
        func level(_ e: Float) -> Int { e >= maxE - 2.5 ? 2 : (e <= maxE - 8 ? 0 : 1) }

        var cues: [CuePoint] = []
        var kindCounts: [CueKind: Int] = [:]
        for (i, bar) in chosen.enumerated() {
            let cur = level(sectionEnergy[i])
            let prev = i > 0 ? level(sectionEnergy[i - 1]) : -1
            let next = i + 1 < chosen.count ? level(sectionEnergy[i + 1]) : -1
            var kind: CueKind
            if i == 0 { kind = .intro }
            else if cur == 2 { kind = .drop }
            else if cur == 0 { kind = prev == 2 ? .breakdown : .verse }
            else { kind = next == 2 && prev != 2 ? .build : (prev == 2 ? .breakdown : .verse) }
            let time = beats[barStarts[bar]]
            if i == chosen.count - 1 && i > 0 && time > duration * 0.7 && cur != 2 { kind = .outro }
            kindCounts[kind, default: 0] += 1
            let count = kindCounts[kind]!
            let name = count > 1 ? "\(kind.defaultName) \(count)" : kind.defaultName
            let energy = DSP.clamp(Int((Float(trackEnergy) + (sectionEnergy[i] - trackMean) / 2).rounded()), 1, 10)
            cues.append(CuePoint(slot: i + 1, name: name, kind: kind, time: time, bar: bar + 1, energy: energy))
        }
        return cues
    }

    /// Snaps a time to the beat grid according to `mode`.
    public static func quantize(time: Double, beats: [Double], downbeatPhase: Int, mode: QuantizeMode) -> (time: Double, bar: Int?) {
        guard let unit = mode.beatsPerUnit, !beats.isEmpty else { return (time, nil) }
        let phase = min(downbeatPhase, beats.count - 1)
        var bestIdx = phase
        var bestDist = Double.infinity
        var i = phase
        // Also consider grid points before the first downbeat.
        var j = phase - unit
        while j >= 0 { let d = abs(beats[j] - time); if d < bestDist { bestDist = d; bestIdx = j }; j -= unit }
        while i < beats.count {
            let d = abs(beats[i] - time)
            if d < bestDist { bestDist = d; bestIdx = i }
            if beats[i] > time + 1 { break }
            i += unit
        }
        let barNumber = (bestIdx - phase) >= 0 ? (bestIdx - phase) / 4 + 1 : nil
        return (beats[bestIdx], barNumber)
    }

    /// Bar number (1-based) for a time on the grid, or nil before the first downbeat.
    public static func barNumber(for time: Double, beats: [Double], downbeatPhase: Int) -> Int? {
        guard !beats.isEmpty else { return nil }
        let phase = min(downbeatPhase, beats.count - 1)
        var idx = phase
        while idx + 1 < beats.count && beats[idx + 1] <= time + 1e-6 { idx += 1 }
        if time < beats[phase] - 1e-6 { return nil }
        return (idx - phase) / 4 + 1
    }
}

/// Maps loudness, rhythm strength and spectral balance to a 1…10 energy level like Mixed In Key.
public enum EnergyAnalyzer {
    public struct Result: Sendable {
        public var level: Int
        public var score: Double
        public var loudnessDb: Double
        public var curve: [Float]
    }

    public static func analyze(samples: [Float], sampleRate: Double, bands: BandEnergies, tempoConfidence: Double, bpm: Double, onset: [Float]) -> Result {
        let n = samples.count
        guard n > 0 else { return Result(level: 1, score: 0, loudnessDb: -80, curve: []) }

        // Integrated loudness (RMS) and short-term blocks.
        let rms = DSP.rms(samples)
        let loudnessDb = 20 * log10(Double(max(rms, 1e-6)))
        let block = Int(sampleRate * 0.4)
        var blocks = [Float]()
        var i = 0
        samples.withUnsafeBufferPointer { p in
            while i + block <= n {
                var r: Float = 0
                vDSP_rmsqv(p.baseAddress! + i, 1, &r, vDSP_Length(block))
                blocks.append(20 * log10f(max(r, 1e-6)))
                i += block
            }
        }
        let loudTop = blocks.isEmpty ? Float(loudnessDb) : DSP.percentile(blocks, 0.9)

        // Spectral balance.
        let totalMean = max(DSP.mean(bands.total), 1e-12)
        let lowRatio = Double(DSP.mean(bands.low) / totalMean)
        let highRatio = Double(DSP.mean(bands.high) / totalMean)

        // Rhythmic activity: how spiky the onset envelope is.
        let onsetMean = Double(DSP.mean(onset))
        let onsetTop = Double(DSP.percentile(onset, 0.95))
        let spikiness = onsetMean > 0 ? DSP.clamp((onsetTop / onsetMean - 2) / 5, 0, 1) : 0

        let loudScore = DSP.clamp((Double(loudTop) + 24) / 16, 0, 1)      // -24 dB → 0, -8 dB → 1
        let bassScore = DSP.clamp(lowRatio / 0.35, 0, 1)
        let brightScore = DSP.clamp(highRatio / 0.08, 0, 1)
        let tempoScore = DSP.clamp((bpm - 80) / 70, 0, 1)
        let score = 0.45 * loudScore + 0.15 * bassScore + 0.12 * brightScore + 0.13 * DSP.clamp(tempoConfidence, 0, 1) + 0.08 * spikiness + 0.07 * tempoScore
        let level = DSP.clamp(Int((1 + 9 * score).rounded()), 1, 10)

        // Per-second curve, normalised 0…1 against the loudest second.
        let sec = Int(sampleRate)
        var curve = [Float]()
        var j = 0
        samples.withUnsafeBufferPointer { p in
            while j < n {
                let len = min(sec, n - j)
                var r: Float = 0
                vDSP_rmsqv(p.baseAddress! + j, 1, &r, vDSP_Length(len))
                curve.append(r)
                j += sec
            }
        }
        let cmax = max(DSP.maxValue(curve), 1e-6)
        curve = curve.map { DSP.clamp($0 / cmax, 0, 1) }
        return Result(level: level, score: score, loudnessDb: loudnessDb, curve: curve)
    }
}
