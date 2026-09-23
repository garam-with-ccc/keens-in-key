import Foundation
import Accelerate

/// Orchestrates decoding and all analyses for one audio file.
public final class TrackAnalyzer {
    public struct Options: Codable, Sendable, Hashable {
        public var keyProfile: KeyProfile = .shaath
        public var keySimilarity: KeyDetector.Similarity = .cosine
        public var keyFrameNormalization: Bool = false
        public var keyOctaves: Int = 7
        public var keyLowestMIDI: Int = 24
        public var keyHarmonicWeights: [Double] = []
        public var keyOctaveDecay: Double = 1.0
        public var keyLogCompression: Double = 0
        public var minBPM: Double = 70
        public var maxBPM: Double = 175
        public var tempoPriorBPM: Double = 125
        public var tempoPriorSigma: Double = 0.9
        public var tempoHarmonicWeights: [Double] = [1.0, 0.5]
        public var tempoBassWeight: Double = 0.0
        public var tempoFluxCompression: Double = 30
        public var cueCount: Int = 8
        public var waveformBuckets: Int = 2000
        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public typealias Progress = (Double, String) -> Void

    /// Runs the full pipeline on `url`.
    public func analyze(url: URL, progress: Progress? = nil) throws -> AnalysisResult {
        progress?(0.02, "Decoding")
        let audio = try AudioDecoder.decodeMono(url: url, targetSampleRate: 44100)
        return try analyze(audio: audio, progress: progress)
    }

    public func analyze(audio: DecodedAudio, progress: Progress? = nil) throws -> AnalysisResult {
        let sr = audio.sampleRate
        let samples = audio.samples
        let duration = Double(samples.count) / sr

        progress?(0.2, "Resampling")
        let s22 = try Resampler.resample(samples, from: sr, to: 22050)
        let s11 = try Resampler.resample(s22, from: 22050, to: 11025)

        progress?(0.3, "Detecting key")
        var keyConfig = KeyDetector.Config()
        keyConfig.profile = options.keyProfile
        keyConfig.similarity = options.keySimilarity
        keyConfig.frameNormalization = options.keyFrameNormalization
        keyConfig.octaves = options.keyOctaves
        keyConfig.lowestMIDI = options.keyLowestMIDI
        keyConfig.harmonicWeights = options.keyHarmonicWeights
        keyConfig.octaveDecay = options.keyOctaveDecay
        keyConfig.logCompression = options.keyLogCompression
        let keyAnalysis = KeyDetector(config: keyConfig).analyze(samples: s11)

        progress?(0.55, "Detecting tempo")
        var tempoConfig = TempoDetector.Config()
        tempoConfig.rangeMin = options.minBPM
        tempoConfig.rangeMax = options.maxBPM
        tempoConfig.priorBPM = options.tempoPriorBPM
        tempoConfig.priorSigma = options.tempoPriorSigma
        tempoConfig.bassWeight = options.tempoBassWeight
        tempoConfig.fluxCompression = options.tempoFluxCompression
        if options.tempoHarmonicWeights.count >= 2 {
            tempoConfig.harmonicWeights = (options.tempoHarmonicWeights[0], options.tempoHarmonicWeights[1])
        }
        let tempoAnalysis = TempoDetector(config: tempoConfig).analyze(samples: s22)
        var tempo = tempoAnalysis.estimate

        progress?(0.8, "Finding structure")
        let features = StructureAnalyzer.beatFeatures(beats: tempo.beats, bands: tempoAnalysis.bands, frameRate: tempoAnalysis.frameRate,
                                                      chromagram: keyAnalysis.chromagram, chromaFrameDuration: keyAnalysis.frameDuration, duration: duration)
        tempo.downbeatPhase = StructureAnalyzer.downbeatPhase(features: features)

        let energy = EnergyAnalyzer.analyze(samples: samples, sampleRate: sr, bands: tempoAnalysis.bands,
                                            tempoConfidence: tempo.confidence, bpm: tempo.bpm, onset: tempoAnalysis.onsetEnvelope)

        var cueConfig = StructureAnalyzer.CueConfig()
        cueConfig.maxCues = options.cueCount
        let cues = StructureAnalyzer.detectCues(beats: tempo.beats, downbeatPhase: tempo.downbeatPhase, features: features,
                                                duration: duration, trackEnergy: energy.level, config: cueConfig)

        progress?(0.95, "Rendering waveform")
        let waveform = TrackAnalyzer.waveform(samples: samples, buckets: options.waveformBuckets)

        progress?(1.0, "Done")
        return AnalysisResult(duration: duration, key: keyAnalysis.estimate, tempo: tempo, energy: energy.level, energyScore: energy.score,
                              loudnessDb: energy.loudnessDb, cuePoints: cues, waveform: waveform, energyCurve: energy.curve)
    }

    /// Peak-per-bucket overview of the waveform, quantised to 0…255.
    public static func waveform(samples: [Float], buckets: Int) -> [UInt8] {
        let n = samples.count
        guard n > 0, buckets > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: buckets)
        let per = Double(n) / Double(buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        samples.withUnsafeBufferPointer { p in
            for b in 0..<buckets {
                let lo = Int(Double(b) * per)
                let hi = min(n, max(lo + 1, Int(Double(b + 1) * per)))
                var m: Float = 0
                vDSP_maxmgv(p.baseAddress! + lo, 1, &m, vDSP_Length(hi - lo))
                peaks[b] = m
            }
        }
        let peak = max(DSP.maxValue(peaks), 1e-6)
        for b in 0..<buckets { out[b] = UInt8(DSP.clamp(Int((peaks[b] / peak * 255).rounded()), 0, 255)) }
        return out
    }
}
