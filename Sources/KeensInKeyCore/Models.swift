import Foundation

public struct KeyCandidate: Codable, Hashable, Sendable {
    public var key: MusicalKey
    public var score: Double
    public init(key: MusicalKey, score: Double) { self.key = key; self.score = score }
}

public struct KeyEstimate: Codable, Hashable, Sendable {
    public var key: MusicalKey
    /// 0…1: how clearly the winning key beats the runner-up.
    public var confidence: Double
    /// Raw similarity score of the winning key (cosine similarity).
    public var strength: Double
    /// Estimated tuning deviation from A440 in semitones (-0.5…0.5).
    public var tuning: Double
    /// Normalised 12-bin chroma (C…B) of the whole track.
    public var chroma: [Double]
    /// Best alternatives, sorted by score (includes the winner first).
    public var candidates: [KeyCandidate]

    public init(key: MusicalKey, confidence: Double, strength: Double, tuning: Double, chroma: [Double], candidates: [KeyCandidate]) {
        self.key = key; self.confidence = confidence; self.strength = strength
        self.tuning = tuning; self.chroma = chroma; self.candidates = candidates
    }
}

public struct BPMCandidate: Codable, Hashable, Sendable {
    public var bpm: Double
    public var score: Double
    public init(bpm: Double, score: Double) { self.bpm = bpm; self.score = score }
}

public struct TempoEstimate: Codable, Hashable, Sendable {
    public var bpm: Double
    /// 0…1 periodicity strength at the detected beat period.
    public var confidence: Double
    /// Beat positions in seconds.
    public var beats: [Double]
    /// Index into `beats` of the first downbeat (0…3).
    public var downbeatPhase: Int
    /// Alternative tempi with their scores.
    public var candidates: [BPMCandidate]

    public init(bpm: Double, confidence: Double, beats: [Double], downbeatPhase: Int, candidates: [BPMCandidate]) {
        self.bpm = bpm; self.confidence = confidence; self.beats = beats
        self.downbeatPhase = downbeatPhase; self.candidates = candidates
    }

    /// Time of the first downbeat, or the first beat.
    public var firstDownbeat: Double {
        guard !beats.isEmpty else { return 0 }
        let idx = min(max(downbeatPhase, 0), beats.count - 1)
        return beats[idx]
    }

    /// Downbeat (bar start) times.
    public var downbeats: [Double] {
        guard !beats.isEmpty else { return [] }
        return stride(from: min(downbeatPhase, beats.count - 1), to: beats.count, by: 4).map { beats[$0] }
    }
}

public enum CueKind: String, Codable, CaseIterable, Sendable {
    case intro, verse, build, drop, breakdown, outro, custom

    public var defaultName: String {
        switch self {
        case .intro: return "Intro"
        case .verse: return "Verse"
        case .build: return "Build"
        case .drop: return "Drop"
        case .breakdown: return "Break"
        case .outro: return "Outro"
        case .custom: return "Cue"
        }
    }

    public var colorHex: String {
        switch self {
        case .intro: return "#3DA9FC"
        case .verse: return "#4CD9C0"
        case .build: return "#F5C242"
        case .drop: return "#F2542D"
        case .breakdown: return "#8BE05C"
        case .outro: return "#B78CF0"
        case .custom: return "#E0E0E0"
        }
    }
}

public struct CuePoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Slot 1…8 (as in hot cues).
    public var slot: Int
    public var name: String
    public var kind: CueKind
    /// Position in seconds.
    public var time: Double
    /// Bar number (1-based) relative to the first downbeat, if quantised.
    public var bar: Int?
    /// Energy level of the section starting at this cue (1…10).
    public var energy: Int

    public init(id: UUID = UUID(), slot: Int, name: String, kind: CueKind, time: Double, bar: Int?, energy: Int) {
        self.id = id; self.slot = slot; self.name = name; self.kind = kind
        self.time = time; self.bar = bar; self.energy = energy
    }
}

public enum QuantizeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, beat, bar, phrase4, phrase8

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .beat: return "Beat"
        case .bar: return "Bar (4 beats)"
        case .phrase4: return "4 bars"
        case .phrase8: return "8 bars"
        }
    }
    public var beatsPerUnit: Int? {
        switch self {
        case .off: return nil
        case .beat: return 1
        case .bar: return 4
        case .phrase4: return 16
        case .phrase8: return 32
        }
    }
}

/// Full result for one file.
public struct AnalysisResult: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var analyzedAt: Date
    public var duration: Double
    public var key: KeyEstimate
    public var tempo: TempoEstimate
    /// 1…10
    public var energy: Int
    /// 0…1 continuous energy score behind `energy`.
    public var energyScore: Double
    /// Integrated RMS loudness in dBFS.
    public var loudnessDb: Double
    public var cuePoints: [CuePoint]
    /// Peak amplitude per bucket (0…255), `waveformBuckets` entries.
    public var waveform: [UInt8]
    /// Per-second energy (0…1) for the energy curve.
    public var energyCurve: [Float]

    public init(version: Int = AnalysisResult.currentVersion, analyzedAt: Date = Date(), duration: Double, key: KeyEstimate, tempo: TempoEstimate, energy: Int, energyScore: Double, loudnessDb: Double, cuePoints: [CuePoint], waveform: [UInt8], energyCurve: [Float]) {
        self.version = version; self.analyzedAt = analyzedAt; self.duration = duration
        self.key = key; self.tempo = tempo; self.energy = energy; self.energyScore = energyScore
        self.loudnessDb = loudnessDb; self.cuePoints = cuePoints; self.waveform = waveform; self.energyCurve = energyCurve
    }
}

public extension Double {
    /// Formats seconds as m:ss or h:mm:ss.
    var timeString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var timeStringMillis: String {
        let total = max(0, self)
        let m = Int(total) / 60
        let s = total - Double(m * 60)
        return String(format: "%d:%06.3f", m, s)
    }
}
