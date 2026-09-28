import Foundation

/// Pure editing operations on an analysis result's cue points and grid (used by the app's cue editor).
public enum CueEditing {
    /// Sorts by time and renumbers slots 1…n.
    public static func normalize(_ cues: inout [CuePoint]) {
        cues.sort { $0.time < $1.time }
        for i in cues.indices { cues[i].slot = i + 1 }
    }

    /// Snaps `time` to the grid and returns the time plus the bar number (1-based, or nil before the first downbeat).
    public static func quantized(_ time: Double, in result: AnalysisResult, mode: QuantizeMode) -> (time: Double, bar: Int?) {
        let q = StructureAnalyzer.quantize(time: time, beats: result.tempo.beats, downbeatPhase: result.tempo.downbeatPhase, mode: mode)
        let bar = q.bar ?? StructureAnalyzer.barNumber(for: q.time, beats: result.tempo.beats, downbeatPhase: result.tempo.downbeatPhase)
        return (q.time, bar)
    }

    /// Adds a cue at `time` (quantized). Returns the new cue, or nil when the slots are full.
    @discardableResult
    public static func add(at time: Double, to result: inout AnalysisResult, mode: QuantizeMode, maxCues: Int = 8, name: String? = nil, kind: CueKind = .custom) -> CuePoint? {
        guard result.cuePoints.count < maxCues else { return nil }
        let (t, bar) = quantized(time, in: result, mode: mode)
        let energy = sectionEnergy(at: t, in: result)
        let cue = CuePoint(slot: result.cuePoints.count + 1, name: name ?? "\(kind.defaultName) \(result.cuePoints.count + 1)", kind: kind, time: t, bar: bar, energy: energy)
        result.cuePoints.append(cue)
        normalize(&result.cuePoints)
        return cue
    }

    public static func move(_ id: UUID, to time: Double, in result: inout AnalysisResult, mode: QuantizeMode) {
        guard let i = result.cuePoints.firstIndex(where: { $0.id == id }) else { return }
        let (t, bar) = quantized(time, in: result, mode: mode)
        result.cuePoints[i].time = t
        result.cuePoints[i].bar = bar
        normalize(&result.cuePoints)
    }

    /// Moves a cue by whole beats along the tracked beat grid.
    public static func nudge(_ id: UUID, beats: Int, in result: inout AnalysisResult) {
        guard let i = result.cuePoints.firstIndex(where: { $0.id == id }), !result.tempo.beats.isEmpty else { return }
        let bs = result.tempo.beats
        let cue = result.cuePoints[i]
        var idx = bs.indices.min(by: { abs(bs[$0] - cue.time) < abs(bs[$1] - cue.time) }) ?? 0
        idx = max(0, min(bs.count - 1, idx + beats))
        result.cuePoints[i].time = bs[idx]
        result.cuePoints[i].bar = StructureAnalyzer.barNumber(for: bs[idx], beats: bs, downbeatPhase: result.tempo.downbeatPhase)
        normalize(&result.cuePoints)
    }

    public static func snapAll(in result: inout AnalysisResult, mode: QuantizeMode) {
        for i in result.cuePoints.indices {
            let (t, bar) = quantized(result.cuePoints[i].time, in: result, mode: mode)
            result.cuePoints[i].time = t
            result.cuePoints[i].bar = bar
        }
        normalize(&result.cuePoints)
    }

    public static func delete(_ id: UUID, in result: inout AnalysisResult) {
        result.cuePoints.removeAll { $0.id == id }
        normalize(&result.cuePoints)
    }

    public static func rename(_ id: UUID, to name: String, in result: inout AnalysisResult) {
        guard let i = result.cuePoints.firstIndex(where: { $0.id == id }) else { return }
        result.cuePoints[i].name = name
    }

    public static func setKind(_ id: UUID, _ kind: CueKind, in result: inout AnalysisResult) {
        guard let i = result.cuePoints.firstIndex(where: { $0.id == id }) else { return }
        let old = result.cuePoints[i]
        let wasDefault = old.name == old.kind.defaultName || old.name.hasPrefix(old.kind.defaultName + " ")
        result.cuePoints[i].kind = kind
        if wasDefault { result.cuePoints[i].name = kind.defaultName }
    }

    /// Rotates the downbeat by `beats` (+1 = next beat becomes the downbeat) and refreshes bar numbers.
    public static func shiftDownbeat(by beats: Int, in result: inout AnalysisResult) {
        guard !result.tempo.beats.isEmpty else { return }
        result.tempo.downbeatPhase = ((result.tempo.downbeatPhase + beats) % 4 + 4) % 4
        for i in result.cuePoints.indices {
            result.cuePoints[i].bar = StructureAnalyzer.barNumber(for: result.cuePoints[i].time, beats: result.tempo.beats, downbeatPhase: result.tempo.downbeatPhase)
        }
    }

    /// Multiplies the tempo (2 = double, 0.5 = halve) and rebuilds the beat grid accordingly.
    public static func scaleTempo(by factor: Double, in result: inout AnalysisResult) {
        guard factor > 0, result.tempo.bpm > 0 else { return }
        let beats = result.tempo.beats
        result.tempo.bpm *= factor
        guard beats.count >= 2 else { return }
        if factor == 2 {
            var out: [Double] = []
            out.reserveCapacity(beats.count * 2)
            for i in 0..<beats.count {
                out.append(beats[i])
                if i + 1 < beats.count { out.append((beats[i] + beats[i + 1]) / 2) }
            }
            result.tempo.beats = out
            result.tempo.downbeatPhase = (result.tempo.downbeatPhase * 2) % 4
        } else if factor == 0.5 {
            let phase = result.tempo.downbeatPhase % 2
            result.tempo.beats = stride(from: phase, to: beats.count, by: 2).map { beats[$0] }
            result.tempo.downbeatPhase = (result.tempo.downbeatPhase / 2) % 4
        } else {
            // Generic: regenerate a constant grid from the first beat.
            let first = beats.first ?? 0
            let period = 60.0 / result.tempo.bpm
            var out: [Double] = []
            var t = first
            let end = beats.last ?? first
            while t <= end + 1e-9 { out.append(t); t += period }
            result.tempo.beats = out
            result.tempo.downbeatPhase = 0
        }
        for i in result.cuePoints.indices {
            result.cuePoints[i].bar = StructureAnalyzer.barNumber(for: result.cuePoints[i].time, beats: result.tempo.beats, downbeatPhase: result.tempo.downbeatPhase)
        }
    }

    /// Overrides the detected key (e.g. a manual correction by the DJ).
    public static func setKey(_ key: MusicalKey, in result: inout AnalysisResult) {
        result.key.key = key
        result.key.confidence = 1
    }

    /// Energy (1…10) of the second around `time`, relative to the track's energy level.
    static func sectionEnergy(at time: Double, in result: AnalysisResult) -> Int {
        guard !result.energyCurve.isEmpty else { return result.energy }
        let idx = max(0, min(result.energyCurve.count - 1, Int(time)))
        let lo = max(0, idx - 4), hi = min(result.energyCurve.count, idx + 4)
        let local = result.energyCurve[lo..<hi].reduce(0, +) / Float(max(1, hi - lo))
        let mean = result.energyCurve.reduce(0, +) / Float(result.energyCurve.count)
        let delta = Double(local - mean) * 6
        return max(1, min(10, Int((Double(result.energy) + delta).rounded())))
    }
}
